import AppKit

// MARK: - Search Methods

extension SearchPanelViewController {
    // MARK: - Search

    /// 缓存的默认搜索网页直达列表

    /// 获取默认搜索网页直达（带缓存）
    func getDefaultSearchWebLinks() -> [SearchResult] {
        if let cached = cachedDefaultSearchWebLinks {
            return cached
        }
        let links = searchEngine.getDefaultSearchWebLinks()
        cachedDefaultSearchWebLinks = links
        return links
    }

    /// 刷新默认搜索网页直达缓存
    func refreshDefaultSearchWebLinksCache() {
        cachedDefaultSearchWebLinks = nil
    }

    func updateCalculatorPreview(_ query: String) {
        if let result = CalculatorService.shared.evaluate(query) {
            calculatorResult = result

            let font = searchField.font ?? NSFont.systemFont(ofSize: 22)
            let resultFont = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
            let resultString = " = \(result)"
            let fullString = query + resultString

            let attributedString = NSMutableAttributedString(string: fullString)
            let nsQuery = query as NSString
            let nsFull = fullString as NSString

            let fullRange = NSRange(location: 0, length: nsFull.length)
            let queryRange = NSRange(location: 0, length: nsQuery.length)
            let resultRange = NSRange(
                location: nsQuery.length, length: (resultString as NSString).length)

            attributedString.addAttribute(.font, value: font, range: fullRange)
            attributedString.addAttribute(.font, value: resultFont, range: resultRange)
            // Make the prefix transparent so it perfectly overlays the search field text
            attributedString.addAttribute(.foregroundColor, value: NSColor.clear, range: queryRange)
            // Show the result as a secondary/placeholder color
            attributedString.addAttribute(
                .foregroundColor, value: NSColor.secondaryLabelColor, range: resultRange)

            calculatorResultLabel.attributedStringValue = attributedString
            calculatorResultLabel.isHidden = false
        } else {
            clearCalculatorResult()
        }
    }

    /// 增量更新 TableView，避免全量 reloadData 造成不必要的 Cell 重绘
    /// 当结果数量变化时使用 insert/remove 动画，否则仅刷新变化行
    private func updateTableViewIncrementally(oldResults: [SearchResult], newResults: [SearchResult]) {
        let oldCount = oldResults.count
        let newCount = newResults.count

        // 简单策略：如果行数变化较大（> 3 行），直接全量刷新更高效
        guard abs(newCount - oldCount) <= 3 && oldCount > 0 && newCount > 0 else {
            tableView.reloadData()
            return
        }

        tableView.beginUpdates()

        if newCount > oldCount {
            // 插入行
            let insertRange = oldCount..<newCount
            let indexSet = IndexSet(integersIn: insertRange)
            tableView.insertRows(at: indexSet, withAnimation: [])
        } else if newCount < oldCount {
            // 删除行
            let removeRange = newCount..<oldCount
            let indexSet = IndexSet(integersIn: removeRange)
            tableView.removeRows(at: indexSet, withAnimation: [])
        }

        // 刷新重叠区域的单元格（内容变化但行数不变时）
        let overlapCount = min(oldCount, newCount)
        if overlapCount > 0 {
            let columnIndexes = IndexSet(integer: 0)
            tableView.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<overlapCount),
                columnIndexes: columnIndexes)
        }

        tableView.endUpdates()
    }

    /// 搜索防抖间隔（秒）：合并快速连续输入，约一帧
    private static let searchDebounceInterval: TimeInterval = 0.02

    func performSearch(_ query: String) {
        // 取消上一次防抖任务（快速连击只保留最后一次）
        searchDebounceWorkItem?.cancel()

        guard !query.isEmpty else {
            // 空查询：bump generation 让在途后台搜索失效，立即在主线程重置
            searchGeneration &+= 1
            applyEmptyQueryResults()
            return
        }

        isShowingRecents = false

        // 防抖：~20ms（约一帧）后触发后台搜索
        let workItem = DispatchWorkItem { [weak self] in
            self?.executeSearchAsync(query: query)
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + SearchPanelViewController.searchDebounceInterval,
            execute: workItem)
    }

    /// 执行一次异步搜索（由防抖任务在主线程调用）
    private func executeSearchAsync(query: String) {
        searchGeneration &+= 1
        let generation = searchGeneration

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            // 后台：仅执行线程安全的重计算（searchSync 内部已加锁）
            let searchResults = self.searchEngine.searchSync(text: query)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 过期结果丢弃：用户已输入新内容或清空输入
                guard self.searchGeneration == generation else { return }
                self.finalizeSearch(query: query, searchResults: searchResults)
            }
        }
    }

    /// 主线程组装最终结果并刷新 UI
    private func finalizeSearch(query: String, searchResults: [SearchResult]) {
        let defaultSearchLinks = getDefaultSearchWebLinks()

        // 过滤掉已经在搜索结果中的默认搜索（避免重复显示）
        let existingPaths = Set(searchResults.map { $0.path })
        let filteredDefaultLinks = defaultSearchLinks.filter { !existingPaths.contains($0.path) }

        // 检查别名匹配（用于显示扩展入口）
        let bookmarkEntryResult = checkBookmarkAliasMatch(query: query)
        let twoFAEntryResult = check2FAAliasMatch(query: query)
        let claudeCodeEntryResult = checkClaudeCodeAliasMatch(query: query)
        let codexEntryResult = checkCodexAliasMatch(query: query)

        // 根据 LRU 对搜索结果重新排序（传入查询字符串用于别名匹配优先级）
        let sortedResults = sortSearchResults(searchResults, query: query)

        // 构建最终结果（扩展入口优先）
        var finalResults: [SearchResult] = []
        if let bookmarkEntry = bookmarkEntryResult { finalResults.append(bookmarkEntry) }
        if let twoFAEntry = twoFAEntryResult { finalResults.append(twoFAEntry) }
        if let claudeCodeEntry = claudeCodeEntryResult { finalResults.append(claudeCodeEntry) }
        if let codexEntry = codexEntryResult { finalResults.append(codexEntry) }

        if sortedResults.isEmpty {
            // 没有搜索结果时，默认搜索显示在最上面
            finalResults.append(contentsOf: filteredDefaultLinks)
        } else {
            // 有搜索结果时，默认搜索显示在最后面
            finalResults.append(contentsOf: sortedResults)
            finalResults.append(contentsOf: filteredDefaultLinks)
        }

        let oldResults = results
        results = finalResults
        selectedIndex = 0
        updateTableViewIncrementally(oldResults: oldResults, newResults: finalResults)
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 空查询时立即（主线程）展示默认结果：待办提醒 + 最近应用
    private func applyEmptyQueryResults() {
        // 扩展模式下直接返回，避免覆盖扩展模式的结果
        if isInAnyExtensionMode { return }

        selectedIndex = 0
        isShowingRecents = false
        let oldResults = results
        results = []

        // 显示待办提醒
        if !reminderResults.isEmpty {
            results.append(contentsOf: reminderResults.prefix(5))
        }

        // Full 模式下显示最近使用的应用
        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"
        if defaultWindowMode == "full" && !recentApps.isEmpty {
            results.append(contentsOf: recentApps)
            isShowingRecents = true
        }

        updateTableViewIncrementally(oldResults: oldResults, newResults: results)
        updateVisibility()
    }

    /// 检查书签别名匹配
    /// - Parameter query: 搜索查询
    /// - Returns: 如果匹配，返回书签入口 SearchResult
    func checkBookmarkAliasMatch(query: String) -> SearchResult? {
        let settings = searchEngine.cachedBookmarkSettings
        guard settings.isEnabled, !settings.alias.isEmpty else { return nil }

        let queryLower = query.lowercased()
        let aliasLower = settings.alias.lowercased()

        // 检查是否匹配别名（前缀匹配或完全匹配）
        guard aliasLower.hasPrefix(queryLower) || queryLower == aliasLower else { return nil }

        // 创建书签入口结果
        let bookmarkIcon =
            NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")
            ?? NSImage()
        bookmarkIcon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: "搜索书签",
            path: "bookmark-entry",
            icon: bookmarkIcon,
            isDirectory: false,
            displayAlias: settings.alias,
            isBookmarkEntry: true
        )
    }

    /// 检查 2FA 别名匹配
    /// - Parameter query: 搜索查询
    /// - Returns: 如果匹配，返回 2FA 入口 SearchResult
    func check2FAAliasMatch(query: String) -> SearchResult? {
        let settings = searchEngine.cachedTwoFactorAuthSettings
        guard settings.isEnabled, !settings.alias.isEmpty else { return nil }

        let queryLower = query.lowercased()
        let aliasLower = settings.alias.lowercased()

        // 检查是否匹配别名（前缀匹配或完全匹配）
        guard aliasLower.hasPrefix(queryLower) || queryLower == aliasLower else { return nil }

        // 创建 2FA 入口结果
        let twoFAIcon =
            NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "2FA")
            ?? NSImage()
        twoFAIcon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: "2FA 短信",
            path: "2fa-entry",
            icon: twoFAIcon,
            isDirectory: false,
            displayAlias: settings.alias,
            is2FAEntry: true
        )
    }

    /// 检查 Claude Code Switcher 别名匹配
    /// - Parameter query: 搜索查询
    /// - Returns: 如果匹配，返回 Claude Code Switcher 入口 SearchResult
    func checkClaudeCodeAliasMatch(query: String) -> SearchResult? {
        let settings = searchEngine.cachedClaudeCodeSettings
        guard settings.isEnabled, !settings.alias.isEmpty else { return nil }

        let queryLower = query.lowercased()
        let aliasLower = settings.alias.lowercased()

        // 检查是否匹配别名（前缀匹配或完全匹配）
        guard aliasLower.hasPrefix(queryLower) || queryLower == aliasLower else { return nil }

        // 创建 Claude Code 入口结果（使用 Claude 官方 logo）
        let ccIcon = NSImage(named: "ClaudeLogo") ?? NSImage()
        ccIcon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: "Claude Code",
            path: "cc-entry",
            icon: ccIcon,
            isDirectory: false,
            displayAlias: settings.alias,
            isClaudeCodeEntry: true
        )
    }

    /// 检查 Codex Switcher 别名匹配
    /// - Parameter query: 搜索查询
    /// - Returns: 如果匹配，返回 Codex Switcher 入口 SearchResult
    func checkCodexAliasMatch(query: String) -> SearchResult? {
        let settings = searchEngine.cachedCodexSettings
        guard settings.isEnabled, !settings.alias.isEmpty else { return nil }

        let queryLower = query.lowercased()
        let aliasLower = settings.alias.lowercased()

        // 检查是否匹配别名（前缀匹配或完全匹配）
        guard aliasLower.hasPrefix(queryLower) || queryLower == aliasLower else { return nil }

        // 创建 Codex 入口结果（使用 OpenAI 官方 logo）
        let codexIcon = NSImage(named: "OpenAILogo") ?? NSImage()
        codexIcon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: "Codex",
            path: "cx-entry",
            icon: codexIcon,
            isDirectory: false,
            displayAlias: settings.alias,
            isCodexEntry: true
        )
    }

    /// 对搜索结果排序（别名完全匹配 > LRU > 其他）
    func sortSearchResults(_ results: [SearchResult], query: String) -> [SearchResult] {
        let queryLower = query.lowercased()
        let recentItems = RecentAppsManager.shared.getRecentItems(limit: 30)

        // path -> LRU 顺序映射
        var lruOrder: [String: Int] = [:]
        for (index, item) in recentItems.enumerated() {
            lruOrder[item.identifier] = index
        }

        // 分离结果：别名完全匹配、LRU 结果、其他结果
        var exactAliasMatches: [SearchResult] = []
        var lruResults: [(result: SearchResult, order: Int)] = []
        var otherResults: [SearchResult] = []

        for result in results {
            // 检查别名是否完全匹配
            if let alias = result.displayAlias?.lowercased(), alias == queryLower {
                exactAliasMatches.append(result)
            } else if let order = lruOrder[result.path] {
                lruResults.append((result, order))
            } else {
                otherResults.append(result)
            }
        }

        // LRU 结果按顺序排序
        lruResults.sort { $0.order < $1.order }

        // 别名完全匹配优先 > LRU > 其他
        return exactAliasMatches + lruResults.map { $0.result } + otherResults
    }

    func updateVisibility() {
        let hasQuery = !searchField.stringValue.isEmpty
        let hasResults = !results.isEmpty
        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"

        // UUID 模式和 URL 模式使用独立视图，隐藏 scrollView
        let isUUIDMode = isInUtilityMode && currentUtilityIdentifier == "uuid"
        let isURLMode = isInUtilityMode && currentUtilityIdentifier == "url"
        let isBase64Mode = isInUtilityMode && currentUtilityIdentifier == "base64"
        let isIndependentViewMode =
            isUUIDMode || isURLMode || isBase64Mode

        // 网页直达 Query 模式下，没有输入时不显示结果列表
        let isWebLinkQueryModeEmpty = isInWebLinkQueryMode && !hasQuery

        divider.isHidden = !hasQuery && !isShowingRecents && !isIndependentViewMode
        scrollView.isHidden = !hasResults || isIndependentViewMode || isWebLinkQueryModeEmpty
        noResultsLabel.isHidden = !hasQuery || hasResults || isIndependentViewMode

        // Update window height
        let isExpanded =
            (defaultWindowMode == "full" || isIndependentViewMode)
            || (hasQuery && hasResults)
            || isInAnyExtensionMode  // 扩展模式下也需要展开

        if defaultWindowMode == "full" || isIndependentViewMode || isInAnyExtensionMode {
            // Full 模式、独立视图模式或扩展模式：始终展开
            updateWindowHeight(expanded: true)
        } else {
            // Simple 模式：有搜索内容且有结果时展开
            updateWindowHeight(expanded: hasQuery && hasResults)
        }

        // 更新底部快捷键提示
        if isExpanded {
            updateShortcutHint()
        } else {
            // 简约模式收起时，隐藏底部提示栏以避免约束冲突和视觉重叠
            shortcutHintView.isHidden = true
        }
    }

    /// 更新底部快捷键提示
    func setupGlobalShortcutHint() {
        shortcutHintView.wantsLayer = true
        shortcutHintView.layer?.cornerRadius = 6
        shortcutHintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        shortcutHintView.translatesAutoresizingMaskIntoConstraints = false
        shortcutHintView.isHidden = true
        contentView.addSubview(shortcutHintView)

        shortcutHintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        shortcutHintLabel.textColor = .secondaryLabelColor
        shortcutHintLabel.stringValue = "⌘K 快捷操作"
        shortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutHintView.addSubview(shortcutHintLabel)

        NSLayoutConstraint.activate([
            shortcutHintView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -16),
            shortcutHintView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -12),
            shortcutHintView.heightAnchor.constraint(equalToConstant: 22),

            shortcutHintLabel.leadingAnchor.constraint(
                equalTo: shortcutHintView.leadingAnchor, constant: 8),
            shortcutHintLabel.trailingAnchor.constraint(
                equalTo: shortcutHintView.trailingAnchor, constant: -8),
            shortcutHintLabel.centerYAnchor.constraint(equalTo: shortcutHintView.centerYAnchor),
        ])
    }

    func updateShortcutHint() {
        // 检查当前选中项是否支持快捷操作
        guard results.indices.contains(selectedIndex) else {
            shortcutHintView.isHidden = true
            return
        }

        let item = results[selectedIndex]

        // 确定哪些类型支持 Cmd+K 快捷操作
        var supportsQuickActions = false

        if item.isReminder {
            // 提醒事项始终显示 ⌘K 提示（用于跳转 App 或链接）
            supportsQuickActions = true
        } else {
            // 还原原始逻辑：仅支持文件和文件夹（排除 .app、网页、工具等）
            let isApp = item.path.hasSuffix(".app")
            let isSpecial =
                item.isWebLink || item.isUtility || item.isSystemCommand
                || item.isBookmark || item.isBookmarkEntry || item.is2FACode
                || item.is2FAEntry || item.isMemeEntry || item.isFavoriteEntry

            if !item.isSectionHeader && !isApp && !isSpecial {
                supportsQuickActions = FileManager.default.fileExists(atPath: item.path)
            }
        }

        if supportsQuickActions {
            shortcutHintLabel.stringValue = "⌘K  快捷操作"
            shortcutHintView.isHidden = false
        } else {
            shortcutHintView.isHidden = true
        }
    }

    func updateWindowHeight(expanded: Bool) {
        guard let window = view.window else { return }

        // Read user's default window mode preference
        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"

        // If user prefers "full" mode, always show expanded view when there's a query
        // If "simple" mode, only expand when there are results
        let shouldExpand: Bool
        if defaultWindowMode == "full" {
            shouldExpand = expanded  // Expand whenever there's a query
        } else {
            shouldExpand = expanded && !results.isEmpty  // Simple mode: only expand with results
        }

        let targetHeight: CGFloat = shouldExpand ? 500 : headerHeight

        // Update the height constraint instead of just the window frame
        contentHeightConstraint?.constant = targetHeight

        let currentFrame = window.frame
        guard abs(currentFrame.height - targetHeight) > 1 else { return }

        let newOriginY = currentFrame.origin.y - (targetHeight - currentFrame.height)
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: currentFrame.width,
            height: targetHeight
        )

        // Disable window's internal constraint updates during frame set
        window.setFrame(newFrame, display: true, animate: false)
    }

}
