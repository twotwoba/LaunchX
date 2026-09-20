import AppKit

// MARK: - Extension Modes

extension SearchPanelViewController {
    // MARK: - Quick Actions Mode

    /// 处理快捷操作模式下的键盘事件
    func handleQuickActionsKeyEvent(_ event: NSEvent) -> NSEvent? {
        switch Int(event.keyCode) {
        case 126:  // Up arrow
            quickActionsView?.moveSelectionUp()
            return nil
        case 125:  // Down arrow
            quickActionsView?.moveSelectionDown()
            return nil
        case 36:  // Return
            quickActionsView?.executeSelectedAction()
            return nil
        case 53:  // Escape
            hideQuickActions()
            return nil
        case 40:  // K (Cmd+K to toggle off)
            if event.modifierFlags.contains(.command) {
                hideQuickActions()
                return nil
            }
            return event
        default:
            // Ctrl+P / Ctrl+N
            if event.modifierFlags.contains(.control) {
                if event.keyCode == 35 {  // P - 上
                    quickActionsView?.moveSelectionUp()
                    return nil
                } else if event.keyCode == 45 {  // N - 下
                    quickActionsView?.moveSelectionDown()
                    return nil
                }
            }
            return event
        }
    }

    /// 尝试显示快捷操作面板
    func tryShowQuickActions() {
        guard results.indices.contains(selectedIndex) else { return }
        let item = results[selectedIndex]

        // 跳过分组标题
        guard !item.isSectionHeader else { return }

        if item.isReminder {
            // 提醒事项：始终显示（用于跳转 App 或链接）
        } else {
            // 还原原始逻辑：只对文件和文件夹显示
            let isApp = item.path.hasSuffix(".app")
            guard
                !isApp && !item.isWebLink && !item.isUtility && !item.isSystemCommand
                    && !item.isBookmark && !item.isBookmarkEntry && !item.is2FACode
                    && !item.is2FAEntry
            else {
                return
            }

            // 验证路径存在
            guard FileManager.default.fileExists(atPath: item.path) else { return }
        }

        showQuickActions(for: item)
    }

    /// 显示快捷操作面板
    func showQuickActions(for item: SearchResult) {
        // 如果已经显示，先隐藏
        hideQuickActions()

        currentQuickActionTarget = item

        if item.isReminder {
            // 提醒事项显示专门的跳转面板
            let actionView = ReminderActionView()
            actionView.delegate = self
            actionView.updateUI(hasURL: item.reminderURL != nil)
            actionView.translatesAutoresizingMaskIntoConstraints = false
            // 确保显示在最顶层，避免被 TableView 或其他视图遮挡
            contentView.addSubview(actionView, positioned: .above, relativeTo: nil)

            // 定位到右下角
            NSLayoutConstraint.activate([
                actionView.trailingAnchor.constraint(
                    equalTo: contentView.trailingAnchor, constant: -12),
                actionView.bottomAnchor.constraint(
                    equalTo: contentView.bottomAnchor, constant: -12),
            ])

            reminderActionView = actionView
            isInQuickActionsMode = true

            // 动画显示
            actionView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                actionView.animator().alphaValue = 1
            }
        } else if isInIDEProjectMode {
            // IDE扩展模式:显示专用的快捷操作(不包含物理删除)
            isInQuickActionsMode = true
            let actions: [QuickActionType] = [
                .openInTerminal, .copyPath, .showInFinder, .removeFromRecent,
            ]
            let actionsView = QuickActionsView(actions: actions)
            actionsView.delegate = self
            actionsView.translatesAutoresizingMaskIntoConstraints = false
            // 确保显示在最顶层
            contentView.addSubview(actionsView, positioned: .above, relativeTo: nil)

            NSLayoutConstraint.activate([
                actionsView.trailingAnchor.constraint(
                    equalTo: contentView.trailingAnchor, constant: -12),
                actionsView.bottomAnchor.constraint(
                    equalTo: contentView.bottomAnchor, constant: -12),
            ])

            quickActionsView = actionsView

            actionsView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                actionsView.animator().alphaValue = 1
            }
        } else {
            // 普通项目显示标准快捷操作
            isInQuickActionsMode = true
            let actions: [QuickActionType] = [
                .openInTerminal, .copyPath, .showInFinder, .airDrop, .delete,
            ]
            let actionsView = QuickActionsView(actions: actions)
            actionsView.delegate = self
            actionsView.translatesAutoresizingMaskIntoConstraints = false
            // 确保显示在最顶层
            contentView.addSubview(actionsView, positioned: .above, relativeTo: nil)

            NSLayoutConstraint.activate([
                actionsView.trailingAnchor.constraint(
                    equalTo: contentView.trailingAnchor, constant: -12),
                actionsView.bottomAnchor.constraint(
                    equalTo: contentView.bottomAnchor, constant: -12),
            ])

            quickActionsView = actionsView

            actionsView.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                actionsView.animator().alphaValue = 1
            }
        }
    }

    func hideQuickActions() {
        isInQuickActionsMode = false
        currentQuickActionTarget = nil

        if let view = quickActionsView {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                view.animator().alphaValue = 0
            }) {
                view.removeFromSuperview()
            }
            quickActionsView = nil
        }

        if let view = reminderActionView {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.1
                view.animator().alphaValue = 0
            }) {
                view.removeFromSuperview()
            }
            reminderActionView = nil
        }
    }

    /// 执行快捷操作
    func executeQuickAction(_ action: QuickActionType) {
        guard let target = currentQuickActionTarget else { return }

        switch action {
        case .openInTerminal:
            quickActionOpenInTerminal(path: target.path, isDirectory: target.isDirectory)
        case .showInFinder:
            quickActionShowInFinder(path: target.path)
        case .copyPath:
            quickActionCopyPath(path: target.path)
        case .airDrop:
            quickActionAirDrop(path: target.path)
        case .openURL:
            if let url = target.reminderURL {
                AppOpener.open(url)
                PanelManager.shared.hidePanel()
            }
        case .openInReminders, .openInApp:
            // 直接打开提醒事项 App，避免 deep link 尝试导致系统弹出“未设定应用程序”弹窗
            RemindersService.shared.openInReminders(identifier: nil)
            PanelManager.shared.hidePanel()
        case .delete:
            quickActionDelete(path: target.path, name: target.name)
        case .removeFromRecent:
            quickActionRemoveFromRecent(project: target)
        }
    }

    /// cd 至此 - 在终端打开新窗口并 cd 到目标位置
    func quickActionOpenInTerminal(path: String, isDirectory: Bool) {
        hideQuickActions()

        let targetPath = isDirectory ? path : (path as NSString).deletingLastPathComponent
        let settings = TerminalSettings.load()
        let terminal = settings.selectedTerminal
        let escapedPath = targetPath.replacingOccurrences(of: "\"", with: "\\\"")

        switch terminal {
        case .appleTerminal:
            let isRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == terminal.bundleIdentifier
            }
            let script: String
            if isRunning {
                script = """
                    tell application "Terminal"
                        activate
                        do script "cd " & quoted form of "\(escapedPath)"
                    end tell
                    """
            } else {
                script = """
                    tell application "Terminal"
                        activate
                        set counter to 0
                        repeat until (count of windows) > 0 or counter > 20
                            delay 0.1
                            set counter to counter + 1
                        end repeat
                        if (count of windows) > 0 then
                            do script "cd " & quoted form of "\(escapedPath)" in window 1
                        else
                            do script "cd " & quoted form of "\(escapedPath)"
                        end if
                    end tell
                    """
            }
            runAppleScript(script)

        case .iterm2:
            let script = """
                tell application "iTerm"
                    activate
                    try
                        if (count of windows) = 0 then
                            create window with default profile
                        else
                            tell current window
                                create tab with default profile
                            end tell
                        end if
                        tell current session of current window
                            write text "cd " & quoted form of "\(escapedPath)"
                        end tell
                    on error
                        create window with default profile
                        tell current session of current window
                            write text "cd " & quoted form of "\(escapedPath)"
                        end tell
                    end try
                end tell
                """
            runAppleScript(script)

        case .warp, .ghostty:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-b", terminal.bundleIdentifier, targetPath]
            do {
                try task.run()
            } catch {
                print("Failed to run open: \(error)")
            }
        }

        PanelManager.shared.hidePanel()
    }

    func runAppleScript(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
        } catch {
            print("Failed to run osascript: \(error)")
        }
    }

    /// 在 Finder 中显示
    func quickActionShowInFinder(path: String) {
        hideQuickActions()

        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])

        PanelManager.shared.hidePanel()
    }

    /// 复制路径
    func quickActionCopyPath(path: String) {
        hideQuickActions()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)

        PanelManager.shared.hidePanel()
    }

    /// 隔空投送
    func quickActionAirDrop(path: String) {
        hideQuickActions()

        let url = URL(fileURLWithPath: path)

        if let service = NSSharingService(named: .sendViaAirDrop) {
            if service.canPerform(withItems: [url]) {
                service.perform(withItems: [url])
            }
        }
    }

    /// 删除（移到废纸篓）
    func quickActionDelete(path: String, name: String) {
        // 显示确认对话框
        let alert = NSAlert()
        alert.messageText = "确定要删除「\(name)」吗？"
        alert.informativeText = "此项目将被移到废纸篓。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")

        // 设置删除按钮为红色
        if let deleteButton = alert.buttons.first {
            deleteButton.hasDestructiveAction = true
        }

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // 用户确认删除
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                hideQuickActions()

                // 从搜索索引中移除
                searchEngine.removeItem(at: path)

                // 从结果中移除该项
                if let index = results.firstIndex(where: { $0.path == path }) {
                    results.remove(at: index)
                    if selectedIndex >= results.count {
                        selectedIndex = max(0, results.count - 1)
                    }
                    tableView.reloadData()
                }
            } catch {
                // 显示错误提示
                let errorAlert = NSAlert()
                errorAlert.messageText = "无法删除「\(name)」"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.alertStyle = .critical
                errorAlert.addButton(withTitle: "确定")
                errorAlert.runModal()
            }
        } else {
            // 用户取消,关闭快捷操作面板
            hideQuickActions()
        }
    }

    /// 从最近列表移除
    func quickActionRemoveFromRecent(project: SearchResult) {
        hideQuickActions()

        guard let ideType = currentIDEType else { return }

        // 调用服务从IDE的最近项目列表中移除
        IDERecentProjectsService.shared.removeRecentProject(
            for: ideType,
            projectPath: project.path
        )

        // 刷新项目列表
        ideProjects = IDERecentProjectsService.shared.getRecentProjects(for: ideType, limit: 20)
        filteredIDEProjects = ideProjects
        results = ideProjects.map { $0.toSearchResult() }

        // 如果移除后列表为空,退出IDE模式
        if results.isEmpty {
            exitIDEProjectMode()
        } else {
            // 调整选中索引
            if selectedIndex >= results.count {
                selectedIndex = max(0, results.count - 1)
            }
            tableView.reloadData()
        }

        // 显示成功提示
        showSuccessMessage("已从最近列表中移除")
    }

    /// 显示成功提示消息
    private func showSuccessMessage(_ message: String) {
        // 创建提示容器
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        // 创建提示标签
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        contentView.addSubview(container, positioned: .above, relativeTo: nil)

        // 居中显示
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            container.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -60),
        ])

        // 动画显示后自动消失
        label.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            label.animator().alphaValue = 1
        } completionHandler: {
            // 1.5秒后消失
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    label.animator().alphaValue = 0
                } completionHandler: {
                    label.removeFromSuperview()
                }
            }
        }
    }

    // MARK: - IDE Project Mode

    /// 尝试进入 IDE 项目模式
    /// - Returns: 是否成功进入
    func tryEnterIDEProjectMode() -> Bool {
        guard results.indices.contains(selectedIndex) else { return false }
        let item = results[selectedIndex]

        // 检测是否为支持的 IDE
        guard let ideType = IDEType.detect(from: item.path) else { return false }

        // 获取该 IDE 的最近项目
        let projects = IDERecentProjectsService.shared.getRecentProjects(for: ideType, limit: 20)
        guard !projects.isEmpty else { return false }

        // 进入 IDE 项目模式
        isInIDEProjectMode = true
        currentIDEApp = item
        currentIDEType = ideType
        ideProjects = projects
        filteredIDEProjects = projects

        // 更新 UI
        updateIDEModeUI()

        // 显示项目列表
        results = projects.map { $0.toSearchResult() }
        selectedIndex = 0
        searchField.stringValue = ""
        setPlaceholder("搜索项目...")
        tableView.reloadData()
        updateVisibility()

        return true
    }

    /// 退出 IDE 项目模式
    func exitIDEProjectMode() {
        isInIDEProjectMode = false
        currentIDEApp = nil
        currentIDEType = nil
        ideProjects = []
        filteredIDEProjects = []

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    /// 更新 IDE 模式 UI
    func updateIDEModeUI() {
        clearCalculatorResult()

        guard let app = currentIDEApp else { return }

        // 显示 IDE 标签
        ideTagView.isHidden = false
        ideIconView.image = app.icon
        ideNameLabel.stringValue = app.name

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true
    }

    /// 恢复普通模式 UI
    func restoreNormalModeUI() {
        // 隐藏 IDE/文件夹 标签
        ideTagView.isHidden = true

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToTag?.isActive = false
        searchFieldLeadingToIcon?.isActive = true
    }

    /// IDE 项目模式下的搜索
    func performIDEProjectSearch(_ query: String) {
        if query.isEmpty {
            filteredIDEProjects = ideProjects
        } else {
            let lowercasedQuery = query.lowercased()
            filteredIDEProjects = ideProjects.filter { project in
                project.name.lowercased().contains(lowercasedQuery)
                    || project.path.lowercased().contains(lowercasedQuery)
            }
        }

        results = filteredIDEProjects.map { $0.toSearchResult() }
        selectedIndex = results.isEmpty ? 0 : 0
        tableView.reloadData()
        updateVisibility()
    }

    // MARK: - Folder Open Mode

    /// 尝试进入文件夹打开方式选择模式
    /// - Returns: 是否成功进入
    func tryEnterFolderOpenMode() -> Bool {
        guard results.indices.contains(selectedIndex) else { return false }
        let item = results[selectedIndex]

        // 检测是否为文件夹（非 .app）
        let isApp = item.path.hasSuffix(".app")
        guard item.isDirectory && !isApp else { return false }

        // 获取可用的打开方式
        let openers = IDERecentProjectsService.shared.getAvailableFolderOpeners()
        guard !openers.isEmpty else { return false }

        // 进入文件夹打开模式
        isInFolderOpenMode = true
        currentFolder = item
        folderOpeners = openers

        // 更新 UI
        updateFolderModeUI()

        // 显示打开方式列表
        results = openers.map { opener in
            SearchResult(
                name: opener.name,
                path: opener.path,
                icon: opener.icon,
                isDirectory: false
            )
        }
        selectedIndex = 0
        searchField.stringValue = ""
        setPlaceholder("选择打开方式...")
        tableView.reloadData()
        updateVisibility()

        return true
    }

    /// 退出文件夹打开模式
    func exitFolderOpenMode() {
        isInFolderOpenMode = false
        currentFolder = nil
        folderOpeners = []

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    /// 更新文件夹打开模式 UI
    func updateFolderModeUI() {
        clearCalculatorResult()

        guard let folder = currentFolder else { return }

        // 显示文件夹标签
        ideTagView.isHidden = false
        ideIconView.image = folder.icon
        ideNameLabel.stringValue = folder.name

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true
    }

    /// 文件夹打开模式下的搜索（过滤打开方式）
    func performFolderOpenerSearch(_ query: String) {
        let filteredOpeners: [IDERecentProjectsService.FolderOpenerApp]
        if query.isEmpty {
            filteredOpeners = folderOpeners
        } else {
            let lowercasedQuery = query.lowercased()
            filteredOpeners = folderOpeners.filter { opener in
                opener.name.lowercased().contains(lowercasedQuery)
            }
        }

        results = filteredOpeners.map { opener in
            SearchResult(
                name: opener.name,
                path: opener.path,
                icon: opener.icon,
                isDirectory: false
            )
        }
        selectedIndex = results.isEmpty ? 0 : 0
        tableView.reloadData()
        updateVisibility()
    }

    // MARK: - 网页直达 Query 模式

    /// 尝试进入网页直达 Query 模式
    func tryEnterWebLinkQueryMode(for item: SearchResult) -> Bool {
        guard item.supportsQueryExtension else { return false }

        isInWebLinkQueryMode = true
        currentWebLinkResult = item

        // 复用 IDE 模式的 UI
        updateWebLinkQueryModeUI()

        // 清空搜索框
        searchField.stringValue = ""
        setPlaceholder("请输入关键词搜索...")

        // 清空结果列表（query 模式下不显示搜索结果）
        results = []
        tableView.reloadData()
        updateVisibility()

        return true
    }

    /// 退出网页直达 Query 模式
    func exitWebLinkQueryMode() {
        isInWebLinkQueryMode = false
        currentWebLinkResult = nil

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    /// 更新网页直达 Query 模式 UI
    func updateWebLinkQueryModeUI() {
        clearCalculatorResult()

        guard let webLink = currentWebLinkResult else { return }

        // 复用 ideTagView 显示网页直达信息
        ideTagView.isHidden = false
        ideIconView.image = webLink.icon
        ideNameLabel.stringValue = webLink.name

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true
    }

    /// 网页直达 Query 模式下打开 URL
    func openWebLinkWithQuery(webLink: SearchResult) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var finalUrl: String?

        if query.isEmpty {
            // 用户没有输入
            if let defaultUrl = webLink.defaultUrl, !defaultUrl.isEmpty {
                // 优先使用默认 URL
                finalUrl = defaultUrl
            } else {
                // 没有设置默认 URL，去掉 {query} 占位符
                finalUrl = webLink.path.replacingOccurrences(of: "{query}", with: "")
            }
        } else {
            // 替换 {query} 占位符
            let encodedQuery =
                query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            finalUrl = webLink.path.replacingOccurrences(of: "{query}", with: encodedQuery)
        }

        if let urlString = finalUrl, let url = URL(string: urlString) {
            AppOpener.open(url)
            // 记录到 LRU 缓存
            RecentAppsManager.shared.recordWebLinkOpen(url: webLink.path, name: webLink.name)
        }

        exitWebLinkQueryMode()
        PanelManager.shared.hidePanel()
    }

    // MARK: - 实用工具模式

    /// 尝试进入实用工具模式
    func tryEnterUtilityMode(for item: SearchResult) -> Bool {
        guard item.isUtility else { return false }

        isInUtilityMode = true
        currentUtilityIdentifier = item.path  // path 存储的是 extensionIdentifier
        currentUtilityResult = item

        // 更新 UI
        updateUtilityModeUI()

        // 根据不同的实用工具类型执行相应操作
        switch item.path {
        case "ip":
            loadIPAddresses()
        case "uuid":
            loadUUIDGenerator()
        case "url":
            loadURLCoder()
        case "base64":
            loadBase64Coder()
        case "kill":
            loadKillModeProcesses()
        default:
            break
        }

        return true
    }

    /// 清理所有扩展模式的 UI（用于切换到不同类型的扩展模式时）
    func cleanupAllExtensionModes() {
        clearCalculatorResult()
        hideQuickActions()

        // 清理 IDE 项目模式
        if isInIDEProjectMode {
            isInIDEProjectMode = false
            currentIDEApp = nil
            currentIDEType = nil
            ideProjects = []
            filteredIDEProjects = []
        }

        // 清理文件夹打开模式
        if isInFolderOpenMode {
            isInFolderOpenMode = false
            currentFolder = nil
            folderOpeners = []
        }

        // 清理网页直达 Query 模式
        if isInWebLinkQueryMode {
            isInWebLinkQueryMode = false
            currentWebLinkResult = nil
        }

        // 清理实用工具模式
        if isInUtilityMode {
            isInUtilityMode = false
            currentUtilityIdentifier = nil
            currentUtilityResult = nil
            cleanupCurrentUtilityModeUI()
        }

        // 清理书签模式
        if isInBookmarkMode {
            isInBookmarkMode = false
            bookmarkResults = []
        }

        // 清理 2FA 模式
        if isIn2FAMode {
            isIn2FAMode = false
            twoFAResults = []
        }

        // 清理 Claude Code 模式
        if isInClaudeCodeMode {
            isInClaudeCodeMode = false
        }

        // 清理 Codex 模式
        if isInCodexMode {
            isInCodexMode = false
        }

        // 恢复 UI
        restoreNormalModeUI()
        searchField.isHidden = false
    }

    /// 清理当前实用工具模式的 UI（用于切换到其他实用工具时）
    func cleanupCurrentUtilityModeUI() {
        // 清理 kill 模式数据
        killModeApps = []
        killModePorts = []
        killModeAllItems = []
        killModeFilteredItems = []

        // 清理 UUID 模式数据和 UI
        generatedUUIDs = []
        uuidOptionsView.isHidden = true
        uuidResultView.isHidden = true

        // 清理 URL 编码解码模式数据和 UI
        urlCoderView.isHidden = true
        decodedURLTextView.string = ""
        encodedURLTextView.string = ""

        // 清理 Base64 编码解码模式数据和 UI
        base64CoderView.isHidden = true
        originalTextView.string = ""
        base64TextView.string = ""

        // 清理 IP 查询数据
        ipQueryResults = []

        // 清理搜索框
        searchField.stringValue = ""

        // 清理表格数据
        results = []
        tableView.reloadData()
    }

    /// 退出实用工具模式
    func exitUtilityMode() {
        isInUtilityMode = false
        currentUtilityIdentifier = nil
        currentUtilityResult = nil
        ipQueryResults = []

        // 清理 kill 模式数据
        killModeApps = []
        killModePorts = []
        killModeAllItems = []
        killModeFilteredItems = []

        // 清理 UUID 模式数据
        generatedUUIDs = []
        uuidOptionsView.isHidden = true

        // 清理 URL 编码解码模式数据
        urlCoderView.isHidden = true

        // 清理 Base64 编码解码模式数据
        base64CoderView.isHidden = true

        // 恢复 UI
        restoreNormalModeUI()
        searchField.isHidden = false  // 恢复搜索框显示

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()

        // 聚焦搜索框，方便用户继续搜索
        view.window?.makeFirstResponder(searchField)
    }

    /// 更新实用工具模式 UI
    func updateUtilityModeUI() {
        clearCalculatorResult()

        guard let result = currentUtilityResult else { return }

        // 复用 ideTagView 显示实用工具信息
        ideTagView.isHidden = false
        ideIconView.image = result.icon
        ideNameLabel.stringValue = result.name

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true

        // 根据实用工具类型决定是否显示搜索框
        // kill 模式需要搜索，uuid 模式需要输入数量，其他模式（如 IP 查询）不需要
        if currentUtilityIdentifier == "kill" {
            searchField.isHidden = false
            searchField.stringValue = ""
            setPlaceholder("请输入关键词搜索")
        } else if currentUtilityIdentifier == "uuid" {
            searchField.isHidden = false
            // uuid 模式的 placeholder 在 loadUUIDGenerator 中设置
        } else {
            searchField.isHidden = true
        }
    }

    @objc func handleEnterIDEModeDirectly(_ notification: Notification) {
        print("SearchPanelViewController: handleEnterIDEModeDirectly called")

        guard let userInfo = notification.userInfo,
            let idePath = userInfo["path"] as? String,
            let ideType = userInfo["ideType"] as? IDEType
        else {
            print("SearchPanelViewController: Invalid notification userInfo")
            return
        }

        print("SearchPanelViewController: IDE path=\(idePath), type=\(ideType)")

        // 获取该 IDE 的最近项目
        let projects = IDERecentProjectsService.shared.getRecentProjects(for: ideType, limit: 20)
        print("SearchPanelViewController: Got \(projects.count) projects")

        guard !projects.isEmpty else {
            print("SearchPanelViewController: No projects found, returning")
            return
        }

        // 创建一个虚拟的 SearchResult 来表示 IDE 应用
        let icon = NSWorkspace.shared.icon(forFile: idePath)
        icon.size = NSSize(width: 32, height: 32)
        let name = FileManager.default.displayName(atPath: idePath)
            .replacingOccurrences(of: ".app", with: "")

        let ideApp = SearchResult(
            name: name,
            path: idePath,
            icon: icon,
            isDirectory: true
        )

        // 如果已经在同一个 IDE 的扩展模式中，忽略重复触发
        if isInIDEProjectMode && currentIDEApp?.path == idePath {
            print("SearchPanelViewController: Already in IDE mode for \(idePath), ignoring")
            return
        }

        // 如果在其他扩展模式中，先清理
        if isInAnyExtensionMode {
            cleanupAllExtensionModes()
        }

        // 进入 IDE 项目模式
        isInIDEProjectMode = true
        currentIDEApp = ideApp
        currentIDEType = ideType
        ideProjects = projects
        filteredIDEProjects = projects

        // 更新 UI
        updateIDEModeUI()

        // 显示项目列表
        results = projects.map { $0.toSearchResult() }
        isShowingRecents = false
        selectedIndex = 0
        searchField.stringValue = ""
        setPlaceholder("搜索项目...")
        tableView.reloadData()
        updateVisibility()

        // 聚焦搜索框
        view.window?.makeFirstResponder(searchField)

        print("SearchPanelViewController: IDE mode setup complete, results count=\(results.count)")
    }

    /// 处理直接进入网页直达 Query 模式的通知
    @objc func handleEnterWebLinkQueryModeDirectly(_ notification: Notification) {
        print("SearchPanelViewController: handleEnterWebLinkQueryModeDirectly called")

        guard let userInfo = notification.userInfo,
            let tool = userInfo["tool"] as? ToolItem
        else {
            print("SearchPanelViewController: Invalid notification userInfo for WebLink query mode")
            return
        }

        print("SearchPanelViewController: WebLink tool=\(tool.name)")

        // 创建一个 SearchResult 来表示网页直达
        var icon: NSImage
        if let iconData = tool.iconData, let customIcon = NSImage(data: iconData) {
            customIcon.size = NSSize(width: 32, height: 32)
            icon = customIcon
        } else {
            icon =
                NSImage(systemSymbolName: "globe", accessibilityDescription: "Web Link")
                ?? NSImage()
            icon.size = NSSize(width: 32, height: 32)
        }

        let webLinkResult = SearchResult(
            name: tool.name,
            path: tool.url ?? "",
            icon: icon,
            isDirectory: false,
            isWebLink: true,
            supportsQueryExtension: true,
            defaultUrl: tool.defaultUrl
        )

        // 如果已经在同一个网页直达的扩展模式中，忽略重复触发
        if isInWebLinkQueryMode && currentWebLinkResult?.path == tool.url {
            print("SearchPanelViewController: Already in WebLink mode for \(tool.name), ignoring")
            return
        }

        // 如果在其他扩展模式中，先清理
        if isInAnyExtensionMode {
            cleanupAllExtensionModes()
        }

        // 进入网页直达 Query 模式
        isInWebLinkQueryMode = true
        currentWebLinkResult = webLinkResult

        // 更新 UI
        updateWebLinkQueryModeUI()

        // 清空结果列表，确保不显示最近使用的app
        results = []
        isShowingRecents = false
        selectedIndex = 0
        searchField.stringValue = ""
        setPlaceholder("请输入关键词搜索...")
        tableView.reloadData()
        updateVisibility()

        // 聚焦搜索框
        view.window?.makeFirstResponder(searchField)

        print("SearchPanelViewController: WebLink query mode setup complete")
    }

    /// 处理直接进入实用工具模式的通知
    @objc func handleEnterUtilityModeDirectly(_ notification: Notification) {
        print("SearchPanelViewController: handleEnterUtilityModeDirectly called")

        guard let userInfo = notification.userInfo,
            let tool = userInfo["tool"] as? ToolItem
        else {
            print("SearchPanelViewController: Invalid notification userInfo for Utility mode")
            return
        }

        // 如果已经在同一个实用工具的扩展模式中，忽略重复触发
        if isInUtilityMode && currentUtilityIdentifier == tool.extensionIdentifier {
            print(
                "SearchPanelViewController: Already in utility mode for \(tool.extensionIdentifier ?? "nil"), ignoring"
            )
            return
        }

        // 如果在其他扩展模式中（包括其他实用工具），先清理
        if isInAnyExtensionMode {
            cleanupAllExtensionModes()
        }

        print(
            "SearchPanelViewController: Utility tool=\(tool.name), identifier=\(tool.extensionIdentifier ?? "nil")"
        )

        // 创建一个 SearchResult 来表示实用工具
        var icon: NSImage
        if let iconData = tool.iconData, let customIcon = NSImage(data: iconData) {
            customIcon.size = NSSize(width: 32, height: 32)
            icon = customIcon
        } else {
            icon =
                NSImage(
                    systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Utility")
                ?? NSImage()
            icon.size = NSSize(width: 32, height: 32)
        }

        let utilityResult = SearchResult(
            name: tool.name,
            path: tool.extensionIdentifier ?? "",
            icon: icon,
            isDirectory: false,
            isUtility: true
        )

        // 进入实用工具模式
        isInUtilityMode = true
        currentUtilityIdentifier = tool.extensionIdentifier
        currentUtilityResult = utilityResult

        // 更新 UI
        updateUtilityModeUI()
        updateVisibility()

        // 根据不同的实用工具类型执行相应操作
        switch tool.extensionIdentifier {
        case "ip":
            loadIPAddresses()
        case "uuid":
            loadUUIDGenerator()
        case "url":
            loadURLCoder()
        case "base64":
            loadBase64Coder()
        case "kill":
            loadKillModeProcesses()
        default:
            break
        }

        print("SearchPanelViewController: Utility mode setup complete")
    }

    /// 处理直接进入书签模式的通知
    @objc func handleEnterBookmarkModeDirectly() {
        print("SearchPanelViewController: handleEnterBookmarkModeDirectly called")

        // 如果已经在书签模式中，刷新数据即可
        if isInBookmarkMode {
            print("SearchPanelViewController: Already in bookmark mode, refreshing")
            loadAllBookmarks()
            return
        }

        // 如果在其他扩展模式中，先清理
        if isInAnyExtensionMode {
            cleanupAllExtensionModes()
        }

        // 进入书签模式
        isInBookmarkMode = true

        // 更新 UI
        updateBookmarkModeUI()

        // 加载所有书签
        loadAllBookmarks()

        print("SearchPanelViewController: Bookmark mode setup complete")
    }

    /// 更新书签模式 UI
    func updateBookmarkModeUI() {
        clearCalculatorResult()

        // 显示 IDE Tag View 作为书签标签
        ideTagView.isHidden = false
        let bookmarkIcon =
            NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "Bookmark")
            ?? NSImage()
        bookmarkIcon.size = NSSize(width: 16, height: 16)
        ideIconView.image = bookmarkIcon
        ideNameLabel.stringValue = "搜索书签"

        // 切换 searchField 的 leading 约束（避免与标签重叠）
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true

        // 更新搜索框占位符
        setPlaceholder("搜索书签...")

        // 清空搜索框
        searchField.stringValue = ""

        // 聚焦搜索框
        view.window?.makeFirstResponder(searchField)
    }

    /// 加载所有书签
    func loadAllBookmarks() {
        bookmarkResults = BookmarkService.shared.getAllBookmarks()

        // 转换为 SearchResult
        results = bookmarkResults.map { bookmark in
            SearchResult(
                name: bookmark.title,
                path: bookmark.url,
                icon: bookmark.source.icon,
                isDirectory: false,
                displayAlias: bookmark.folderPath.isEmpty ? nil : bookmark.folderPath.last,
                isBookmark: true,
                bookmarkSource: bookmark.source.rawValue
            )
        }

        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 书签模式搜索
    func performBookmarkSearch(_ query: String) {
        let filteredBookmarks: [BookmarkItem]
        if query.isEmpty {
            filteredBookmarks = bookmarkResults
        } else {
            filteredBookmarks = BookmarkService.shared.search(query: query)
        }

        results = filteredBookmarks.map { bookmark in
            SearchResult(
                name: bookmark.title,
                path: bookmark.url,
                icon: bookmark.source.icon,
                isDirectory: false,
                displayAlias: bookmark.folderPath.isEmpty ? nil : bookmark.folderPath.last,
                isBookmark: true,
                bookmarkSource: bookmark.source.rawValue
            )
        }

        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 退出书签模式
    func exitBookmarkMode() {
        guard isInBookmarkMode else { return }

        isInBookmarkMode = false
        bookmarkResults = []

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    /// 进入书签模式（通过别名搜索选择）
    func enterBookmarkMode() {
        // 如果在其他扩展模式中，先清理
        if isInIDEProjectMode || isInFolderOpenMode || isInWebLinkQueryMode || isInUtilityMode {
            cleanupAllExtensionModes()
        }

        // 进入书签模式
        isInBookmarkMode = true

        // 更新 UI
        updateBookmarkModeUI()

        // 加载所有书签
        loadAllBookmarks()

        print("SearchPanelViewController: Entered bookmark mode via alias")
    }

    /// 进入 2FA 模式（通过别名搜索选择）
    func enter2FAMode() {
        // 如果在其他扩展模式中，先清理
        if isInIDEProjectMode || isInFolderOpenMode || isInWebLinkQueryMode || isInUtilityMode
            || isInBookmarkMode
        {
            cleanupAllExtensionModes()
        }

        // 进入 2FA 模式
        isIn2FAMode = true

        // 更新 UI
        update2FAModeUI()

        // 加载所有验证码
        loadAll2FACodes()

        print("SearchPanelViewController: Entered 2FA mode via alias")
    }

    // MARK: - 2FA 短信模式

    /// 处理直接进入 2FA 模式的通知
    @objc func handleEnter2FAModeDirectly() {
        print("SearchPanelViewController: handleEnter2FAModeDirectly called")

        // 如果已经在 2FA 模式中，刷新数据即可
        if isIn2FAMode {
            print("SearchPanelViewController: Already in 2FA mode, refreshing")
            loadAll2FACodes()
            return
        }

        // 如果在其他扩展模式中，先清理
        if isInAnyExtensionMode {
            cleanupAllExtensionModes()
        }

        // 进入 2FA 模式
        isIn2FAMode = true

        // 更新 UI
        update2FAModeUI()

        // 加载所有验证码
        loadAll2FACodes()

        print("SearchPanelViewController: 2FA mode setup complete")
    }

    /// 更新 2FA 模式 UI
    func update2FAModeUI() {
        clearCalculatorResult()

        // 显示 IDE Tag View 作为 2FA 标签
        ideTagView.isHidden = false
        let twoFAIcon =
            NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "2FA")
            ?? NSImage()
        twoFAIcon.size = NSSize(width: 16, height: 16)
        ideIconView.image = twoFAIcon
        ideNameLabel.stringValue = "2FA 短信"

        // 切换 searchField 的 leading 约束（避免与标签重叠）
        searchFieldLeadingToIcon?.isActive = false
        searchFieldLeadingToTag?.isActive = true

        // 更新搜索框占位符
        setPlaceholder("搜索验证码...")

        // 清空搜索框
        searchField.stringValue = ""

        // 聚焦搜索框
        view.window?.makeFirstResponder(searchField)
    }

    /// 加载所有 2FA 验证码
    func loadAll2FACodes() {
        let settings = TwoFactorAuthSettings.load()
        twoFAResults = TwoFactorAuthService.shared.getRecentCodes(
            timeSpanMinutes: settings.timeSpanMinutes)

        // 转换为 SearchResult
        results = twoFAResults.map { code in
            SearchResult(
                name: "验证码: \(code.code)",
                path: "\(code.sender) · \(code.formattedTime)",
                icon: NSImage(
                    systemSymbolName: "number.circle.fill", accessibilityDescription: "Code")
                    ?? NSImage(),
                isDirectory: false,
                displayAlias: nil,
                is2FACode: true
            )
        }

        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 2FA 模式搜索
    func perform2FASearch(_ query: String) {
        let filteredCodes: [TwoFactorCodeItem]
        if query.isEmpty {
            filteredCodes = twoFAResults
        } else {
            // 搜索验证码或发送者
            filteredCodes = twoFAResults.filter { code in
                code.code.contains(query) || code.sender.localizedCaseInsensitiveContains(query)
                    || code.fullMessage.localizedCaseInsensitiveContains(query)
            }
        }

        results = filteredCodes.map { code in
            SearchResult(
                name: "验证码: \(code.code)",
                path: "\(code.sender) · \(code.formattedTime)",
                icon: NSImage(
                    systemSymbolName: "number.circle.fill", accessibilityDescription: "Code")
                    ?? NSImage(),
                isDirectory: false,
                displayAlias: nil,
                is2FACode: true
            )
        }

        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 退出 2FA 模式
    func exit2FAMode() {
        guard isIn2FAMode else { return }

        isIn2FAMode = false
        twoFAResults = []

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    // MARK: - Claude Code Switcher 模式

    /// 直接进入 Claude Code Switcher 模式（由快捷键触发）
    @objc func handleEnterClaudeCodeModeDirectly() {
        PanelManager.shared.showPanel()
        enterClaudeCodeMode()
    }

    /// 进入 Claude Code Switcher 模式
    func enterClaudeCodeMode() {
        // 如果在其他扩展模式中，先清理
        if isInAnyExtensionMode && !isInClaudeCodeMode {
            cleanupAllExtensionModes()
        }

        isInClaudeCodeMode = true
        updateClaudeCodeModeUI()
        loadClaudeCodeItems()

        searchField.stringValue = ""
        view.window?.makeFirstResponder(searchField)
    }

    /// 更新 Claude Code Switcher 模式 UI
    func updateClaudeCodeModeUI() {
        setPlaceholder("搜索 Provider / 上下文 / MCP / Skills...")
    }

    /// 加载 Claude Code 项目列表
    func loadClaudeCodeItems() {
        var items: [SearchResult] = []

        // Provider 分组（仅 Claude Code）
        let providers = ClaudeProviderService.shared.providers.filter { $0.apps.contains(.claude) }
        let currentProviderId = ClaudeProviderService.shared.currentClaudeProvider?.id

        let providerHeaderIcon =
            NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Provider")
            ?? NSImage()
        providerHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "Provider",
                path: "",
                icon: providerHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for provider in providers {
            let isActive = provider.id == currentProviderId
            let icon: NSImage
            if isActive {
                let baseImage =
                    NSImage(
                        systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let config = NSImage.SymbolConfiguration(paletteColors: [
                    .systemGreen, .systemGreen.withAlphaComponent(0.15),
                ])
                icon = baseImage.withSymbolConfiguration(config) ?? baseImage
            } else {
                icon =
                    NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
            }
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: provider.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: isActive ? "当前" : nil,
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .provider,
                    claudeCodeItemId: provider.id.uuidString
                ))
        }

        // 上下文分组（仅 Claude Code）
        let ctxPrompts = ContextPromptService.shared.prompts.filter { $0.apps.contains(.claude) }
        let currentCtxPromptId = ContextPromptService.shared.currentClaudePrompt?.id

        let ctxHeaderIcon =
            NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "上下文")
            ?? NSImage()
        ctxHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "上下文",
                path: "",
                icon: ctxHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for prompt in ctxPrompts {
            let isActive = prompt.id == currentCtxPromptId
            let icon = makeClaudeCodeIcon(isActive: isActive)
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: prompt.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: isActive ? "当前" : nil,
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .contextPrompt,
                    claudeCodeItemId: prompt.id.uuidString
                ))
        }

        // MCP 分组（仅 Claude Code）
        let mcpServers = ClaudeMcpService.shared.servers.filter { $0.apps.contains(.claude) }

        let mcpHeaderIcon =
            NSImage(systemSymbolName: "link.circle", accessibilityDescription: "MCP")
            ?? NSImage()
        mcpHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "MCP",
                path: "",
                icon: mcpHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for server in mcpServers {
            let icon: NSImage
            if server.isEnabled {
                let baseImage =
                    NSImage(
                        systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let config = NSImage.SymbolConfiguration(paletteColors: [
                    .systemGreen, .systemGreen.withAlphaComponent(0.15),
                ])
                icon = baseImage.withSymbolConfiguration(config) ?? baseImage
            } else {
                icon =
                    NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
            }
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: server.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: server.isEnabled ? "已启用" : "已禁用",
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .mcp,
                    claudeCodeItemId: server.id.uuidString
                ))
        }

        // Skills 分组（仅 Claude Code）
        let skills = ClaudeSkillService.shared.skills.filter { $0.apps.contains(.claude) }

        let skillHeaderIcon =
            NSImage(systemSymbolName: "star.circle", accessibilityDescription: "Skills")
            ?? NSImage()
        skillHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "Skills",
                path: "",
                icon: skillHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for skill in skills {
            let icon: NSImage
            if skill.isEnabled {
                let baseImage =
                    NSImage(
                        systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                    ?? NSImage()
                let config = NSImage.SymbolConfiguration(paletteColors: [
                    .systemGreen, .systemGreen.withAlphaComponent(0.15),
                ])
                icon = baseImage.withSymbolConfiguration(config) ?? baseImage
            } else {
                icon =
                    NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
            }
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: skill.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: skill.isEnabled ? "已启用" : "已禁用",
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .skill,
                    claudeCodeItemId: skill.id.uuidString
                ))
        }

        results = items
        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            // 选中第一个非分组标题的项
            for i in results.indices {
                if !results[i].isSectionHeader {
                    selectedIndex = i
                    break
                }
            }
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 在 Claude Code 模式中搜索过滤
    func filterClaudeCodeItems(query: String) {
        guard isInClaudeCodeMode else { return }

        if query.isEmpty {
            loadClaudeCodeItems()
            return
        }

        let queryLower = query.lowercased()

        var items: [SearchResult] = []

        // Provider 过滤（仅 Claude Code）
        let providers = ClaudeProviderService.shared.providers.filter {
            $0.apps.contains(.claude) && $0.name.lowercased().contains(queryLower)
        }
        let currentProviderId = ClaudeProviderService.shared.currentClaudeProvider?.id

        if !providers.isEmpty {
            let providerHeaderIcon =
                NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Provider")
                ?? NSImage()
            providerHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "Provider", path: "", icon: providerHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for provider in providers {
                let isActive = provider.id == currentProviderId
                let icon: NSImage
                if isActive {
                    let baseImage =
                        NSImage(
                            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil
                        ) ?? NSImage()
                    let config = NSImage.SymbolConfiguration(paletteColors: [
                        .systemGreen, .systemGreen.withAlphaComponent(0.15),
                    ])
                    icon = baseImage.withSymbolConfiguration(config) ?? baseImage
                } else {
                    icon =
                        NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
                        ?? NSImage()
                }
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: provider.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: isActive ? "当前" : nil,
                        isClaudeCodeItem: true, claudeCodeItemType: .provider,
                        claudeCodeItemId: provider.id.uuidString))
            }
        }

        // 上下文过滤（仅 Claude Code）
        let ctxPrompts = ContextPromptService.shared.prompts.filter {
            $0.apps.contains(.claude) && $0.name.lowercased().contains(queryLower)
        }
        let currentCtxPromptId = ContextPromptService.shared.currentClaudePrompt?.id

        if !ctxPrompts.isEmpty {
            let ctxHeaderIcon =
                NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "上下文")
                ?? NSImage()
            ctxHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "上下文", path: "", icon: ctxHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for prompt in ctxPrompts {
                let isActive = prompt.id == currentCtxPromptId
                let icon = makeClaudeCodeIcon(isActive: isActive)
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: prompt.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: isActive ? "当前" : nil,
                        isClaudeCodeItem: true, claudeCodeItemType: .contextPrompt,
                        claudeCodeItemId: prompt.id.uuidString))
            }
        }

        // MCP 过滤（仅 Claude Code）
        let mcpServers = ClaudeMcpService.shared.servers.filter {
            $0.apps.contains(.claude) && $0.name.lowercased().contains(queryLower)
        }

        if !mcpServers.isEmpty {
            let mcpHeaderIcon =
                NSImage(systemSymbolName: "link.circle", accessibilityDescription: "MCP")
                ?? NSImage()
            mcpHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "MCP", path: "", icon: mcpHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for server in mcpServers {
                let icon: NSImage
                if server.isEnabled {
                    let baseImage =
                        NSImage(
                            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil
                        ) ?? NSImage()
                    let config = NSImage.SymbolConfiguration(paletteColors: [
                        .systemGreen, .systemGreen.withAlphaComponent(0.15),
                    ])
                    icon = baseImage.withSymbolConfiguration(config) ?? baseImage
                } else {
                    icon =
                        NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
                        ?? NSImage()
                }
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: server.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: server.isEnabled ? "已启用" : "已禁用",
                        isClaudeCodeItem: true, claudeCodeItemType: .mcp,
                        claudeCodeItemId: server.id.uuidString))
            }
        }

        // Skills 过滤（仅 Claude Code）
        let skills = ClaudeSkillService.shared.skills.filter {
            $0.apps.contains(.claude) && $0.name.lowercased().contains(queryLower)
        }

        if !skills.isEmpty {
            let skillHeaderIcon =
                NSImage(systemSymbolName: "star.circle", accessibilityDescription: "Skills")
                ?? NSImage()
            skillHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "Skills", path: "", icon: skillHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for skill in skills {
                let icon: NSImage
                if skill.isEnabled {
                    let baseImage =
                        NSImage(
                            systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil
                        ) ?? NSImage()
                    let config = NSImage.SymbolConfiguration(paletteColors: [
                        .systemGreen, .systemGreen.withAlphaComponent(0.15),
                    ])
                    icon = baseImage.withSymbolConfiguration(config) ?? baseImage
                } else {
                    icon =
                        NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
                        ?? NSImage()
                }
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: skill.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: skill.isEnabled ? "已启用" : "已禁用",
                        isClaudeCodeItem: true, claudeCodeItemType: .skill,
                        claudeCodeItemId: skill.id.uuidString))
            }
        }

        results = items
        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            for i in results.indices {
                if !results[i].isSectionHeader {
                    selectedIndex = i
                    break
                }
            }
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    // MARK: - Claude Code 行就地更新辅助方法

    /// 生成 Claude Code 项的图标
    private func makeClaudeCodeIcon(isActive: Bool) -> NSImage {
        let icon: NSImage
        if isActive {
            let baseImage =
                NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                ?? NSImage()
            let config = NSImage.SymbolConfiguration(paletteColors: [
                .systemGreen, .systemGreen.withAlphaComponent(0.15),
            ])
            icon = baseImage.withSymbolConfiguration(config) ?? baseImage
        } else {
            icon = NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage()
        }
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    /// 刷新指定行（不重建整个列表、不改变滚动位置）
    private func reloadClaudeCodeRows(at indices: [Int]) {
        let indexSet = IndexSet(indices)
        tableView.reloadData(forRowIndexes: indexSet, columnIndexes: IndexSet(integer: 0))
    }

    /// 处理 Claude Code 模式中的选中项
    func handleClaudeCodeItemSelected(_ item: SearchResult) {
        guard item.isClaudeCodeItem, let itemType = item.claudeCodeItemType,
            let itemIdStr = item.claudeCodeItemId,
            let itemUUID = UUID(uuidString: itemIdStr)
        else { return }

        switch itemType {
        case .provider:
            // 切换 Provider
            guard
                let provider = ClaudeProviderService.shared.providers.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            do {
                try ClaudeProviderService.shared.switchProvider(to: provider)
            } catch {
                print("Claude Code Switcher: 切换 Provider 失败: \(error)")
            }
            // 就地更新所有 Provider 行的图标和状态
            var rowsToReload: [Int] = []
            for i in results.indices {
                guard results[i].claudeCodeItemType == .provider,
                    let rowIdStr = results[i].claudeCodeItemId
                else { continue }
                let isActive = rowIdStr == itemUUID.uuidString
                results[i].icon = makeClaudeCodeIcon(isActive: isActive)
                results[i].displayAlias = isActive ? "当前" : nil
                rowsToReload.append(i)
            }
            reloadClaudeCodeRows(at: rowsToReload)

        case .contextPrompt:
            // 切换上下文预设
            guard
                let prompt = ContextPromptService.shared.prompts.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            do {
                try ContextPromptService.shared.switchPrompt(to: prompt, for: .claude)
            } catch {
                print("Claude Code Switcher: 切换上下文失败: \(error)")
            }
            // 就地更新所有上下文行的图标和状态
            let activePromptId = ContextPromptService.shared.currentClaudePrompt?.id
            var ctxRowsToReload: [Int] = []
            for i in results.indices {
                guard results[i].claudeCodeItemType == .contextPrompt,
                    let rowIdStr = results[i].claudeCodeItemId
                else { continue }
                let isActive = rowIdStr == activePromptId?.uuidString
                results[i].icon = makeClaudeCodeIcon(isActive: isActive)
                results[i].displayAlias = isActive ? "当前" : nil
                ctxRowsToReload.append(i)
            }
            reloadClaudeCodeRows(at: ctxRowsToReload)

        case .mcp:
            // 切换 MCP 启用/禁用
            guard
                let server = ClaudeMcpService.shared.servers.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            let newEnabled = !server.isEnabled
            do {
                try ClaudeMcpService.shared.toggleEnabled(server)
            } catch {
                print("Claude Code Switcher: 切换 MCP 失败: \(error)")
            }
            // 就地更新该行
            if let rowIndex = results.firstIndex(where: {
                $0.claudeCodeItemId == itemUUID.uuidString
            }) {
                results[rowIndex].icon = makeClaudeCodeIcon(isActive: newEnabled)
                results[rowIndex].displayAlias = newEnabled ? "已启用" : "已禁用"
                reloadClaudeCodeRows(at: [rowIndex])
            }

        case .skill:
            // 切换 Skill 启用/禁用
            guard
                let skill = ClaudeSkillService.shared.skills.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            let newEnabled = !skill.isEnabled
            do {
                try ClaudeSkillService.shared.toggleEnabled(skill)
            } catch {
                print("Claude Code Switcher: 切换 Skill 失败: \(error)")
            }
            // 就地更新该行
            if let rowIndex = results.firstIndex(where: {
                $0.claudeCodeItemId == itemUUID.uuidString
            }) {
                results[rowIndex].icon = makeClaudeCodeIcon(isActive: newEnabled)
                results[rowIndex].displayAlias = newEnabled ? "已启用" : "已禁用"
                reloadClaudeCodeRows(at: [rowIndex])
            }
        }
    }

    /// 退出 Claude Code Switcher 模式
    func exitClaudeCodeMode() {
        guard isInClaudeCodeMode else { return }

        isInClaudeCodeMode = false

        // 恢复 UI
        restoreNormalModeUI()

        // 恢复搜索状态
        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

    // MARK: - Codex Switcher 模式

    /// 直接进入 Codex Switcher 模式（由快捷键触发）
    @objc func handleEnterCodexModeDirectly() {
        PanelManager.shared.showPanel()
        enterCodexMode()
    }

    /// 进入 Codex Switcher 模式
    func enterCodexMode() {
        if isInAnyExtensionMode && !isInCodexMode {
            cleanupAllExtensionModes()
        }

        isInCodexMode = true
        setPlaceholder("搜索 Provider / 上下文 / MCP / Skills...")
        loadCodexItems()

        searchField.stringValue = ""
        view.window?.makeFirstResponder(searchField)
    }

    /// 加载 Codex 项目列表
    func loadCodexItems() {
        var items: [SearchResult] = []

        // Provider 分组（仅 Codex）
        let providers = ClaudeProviderService.shared.providers.filter { $0.apps.contains(.codex) }
        let currentProviderId = ClaudeProviderService.shared.currentCodexProvider?.id

        let providerHeaderIcon =
            NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Provider")
            ?? NSImage()
        providerHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "Provider",
                path: "",
                icon: providerHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for provider in providers {
            let isActive = provider.id == currentProviderId
            let icon = makeClaudeCodeIcon(isActive: isActive)
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: provider.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: isActive ? "当前" : nil,
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .provider,
                    claudeCodeItemId: provider.id.uuidString
                ))
        }

        // 上下文分组（仅 Codex）
        let ctxPrompts = ContextPromptService.shared.prompts.filter { $0.apps.contains(.codex) }
        let currentCtxPromptId = ContextPromptService.shared.currentCodexPrompt?.id

        let ctxHeaderIcon =
            NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "上下文")
            ?? NSImage()
        ctxHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "上下文",
                path: "",
                icon: ctxHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for prompt in ctxPrompts {
            let isActive = prompt.id == currentCtxPromptId
            let icon = makeClaudeCodeIcon(isActive: isActive)
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: prompt.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: isActive ? "当前" : nil,
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .contextPrompt,
                    claudeCodeItemId: prompt.id.uuidString
                ))
        }

        // MCP 分组（仅 Codex）
        let mcpServers = ClaudeMcpService.shared.servers.filter { $0.apps.contains(.codex) }

        let mcpHeaderIcon =
            NSImage(systemSymbolName: "link.circle", accessibilityDescription: "MCP")
            ?? NSImage()
        mcpHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "MCP",
                path: "",
                icon: mcpHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for server in mcpServers {
            let icon = makeClaudeCodeIcon(isActive: server.isEnabled)
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: server.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: server.isEnabled ? "已启用" : "已禁用",
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .mcp,
                    claudeCodeItemId: server.id.uuidString
                ))
        }

        // Skills 分组（仅 Codex）
        let skills = ClaudeSkillService.shared.skills.filter { $0.apps.contains(.codex) }

        let skillHeaderIcon =
            NSImage(systemSymbolName: "star.circle", accessibilityDescription: "Skills")
            ?? NSImage()
        skillHeaderIcon.size = NSSize(width: 32, height: 32)

        items.append(
            SearchResult(
                name: "Skills",
                path: "",
                icon: skillHeaderIcon,
                isDirectory: false,
                isSectionHeader: true
            ))

        for skill in skills {
            let icon = makeClaudeCodeIcon(isActive: skill.isEnabled)
            icon.size = NSSize(width: 32, height: 32)

            items.append(
                SearchResult(
                    name: skill.name,
                    path: "",
                    icon: icon,
                    isDirectory: false,
                    displayAlias: skill.isEnabled ? "已启用" : "已禁用",
                    isClaudeCodeItem: true,
                    claudeCodeItemType: .skill,
                    claudeCodeItemId: skill.id.uuidString
                ))
        }

        results = items
        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            for i in results.indices {
                if !results[i].isSectionHeader {
                    selectedIndex = i
                    break
                }
            }
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 在 Codex 模式中搜索过滤
    func filterCodexItems(query: String) {
        guard isInCodexMode else { return }

        if query.isEmpty {
            loadCodexItems()
            return
        }

        let queryLower = query.lowercased()

        var items: [SearchResult] = []

        // Provider 过滤（仅 Codex）
        let providers = ClaudeProviderService.shared.providers.filter {
            $0.apps.contains(.codex) && $0.name.lowercased().contains(queryLower)
        }
        let currentProviderId = ClaudeProviderService.shared.currentCodexProvider?.id

        if !providers.isEmpty {
            let providerHeaderIcon =
                NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Provider")
                ?? NSImage()
            providerHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "Provider", path: "", icon: providerHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for provider in providers {
                let isActive = provider.id == currentProviderId
                let icon = makeClaudeCodeIcon(isActive: isActive)
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: provider.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: isActive ? "当前" : nil,
                        isClaudeCodeItem: true, claudeCodeItemType: .provider,
                        claudeCodeItemId: provider.id.uuidString))
            }
        }

        // 上下文过滤（仅 Codex）
        let ctxPrompts = ContextPromptService.shared.prompts.filter {
            $0.apps.contains(.codex) && $0.name.lowercased().contains(queryLower)
        }
        let currentCtxPromptId = ContextPromptService.shared.currentCodexPrompt?.id

        if !ctxPrompts.isEmpty {
            let ctxHeaderIcon =
                NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "上下文")
                ?? NSImage()
            ctxHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "上下文", path: "", icon: ctxHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for prompt in ctxPrompts {
                let isActive = prompt.id == currentCtxPromptId
                let icon = makeClaudeCodeIcon(isActive: isActive)
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: prompt.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: isActive ? "当前" : nil,
                        isClaudeCodeItem: true, claudeCodeItemType: .contextPrompt,
                        claudeCodeItemId: prompt.id.uuidString))
            }
        }

        // MCP 过滤（仅 Codex）
        let mcpServers = ClaudeMcpService.shared.servers.filter {
            $0.apps.contains(.codex) && $0.name.lowercased().contains(queryLower)
        }

        if !mcpServers.isEmpty {
            let mcpHeaderIcon =
                NSImage(systemSymbolName: "link.circle", accessibilityDescription: "MCP")
                ?? NSImage()
            mcpHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "MCP", path: "", icon: mcpHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for server in mcpServers {
                let icon = makeClaudeCodeIcon(isActive: server.isEnabled)
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: server.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: server.isEnabled ? "已启用" : "已禁用",
                        isClaudeCodeItem: true, claudeCodeItemType: .mcp,
                        claudeCodeItemId: server.id.uuidString))
            }
        }

        // Skills 过滤（仅 Codex）
        let skills = ClaudeSkillService.shared.skills.filter {
            $0.apps.contains(.codex) && $0.name.lowercased().contains(queryLower)
        }

        if !skills.isEmpty {
            let skillHeaderIcon =
                NSImage(systemSymbolName: "star.circle", accessibilityDescription: "Skills")
                ?? NSImage()
            skillHeaderIcon.size = NSSize(width: 32, height: 32)
            items.append(
                SearchResult(
                    name: "Skills", path: "", icon: skillHeaderIcon,
                    isDirectory: false, isSectionHeader: true))

            for skill in skills {
                let icon = makeClaudeCodeIcon(isActive: skill.isEnabled)
                icon.size = NSSize(width: 32, height: 32)
                items.append(
                    SearchResult(
                        name: skill.name, path: "", icon: icon,
                        isDirectory: false, displayAlias: skill.isEnabled ? "已启用" : "已禁用",
                        isClaudeCodeItem: true, claudeCodeItemType: .skill,
                        claudeCodeItemId: skill.id.uuidString))
            }
        }

        results = items
        selectedIndex = 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            for i in results.indices {
                if !results[i].isSectionHeader {
                    selectedIndex = i
                    break
                }
            }
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    /// 处理 Codex 模式选中项
    func handleCodexItemSelected(_ item: SearchResult) {
        guard item.isClaudeCodeItem, let itemType = item.claudeCodeItemType,
            let itemIdStr = item.claudeCodeItemId,
            let itemUUID = UUID(uuidString: itemIdStr)
        else { return }

        switch itemType {
        case .provider:
            guard
                let provider = ClaudeProviderService.shared.providers.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            do {
                try ClaudeProviderService.shared.switchProvider(to: provider)
            } catch {
                print("Codex Switcher: 切换 Provider 失败: \(error)")
            }
            var rowsToReload: [Int] = []
            for i in results.indices {
                guard results[i].claudeCodeItemType == .provider,
                    let rowIdStr = results[i].claudeCodeItemId
                else { continue }
                let isActive = rowIdStr == itemUUID.uuidString
                results[i].icon = makeClaudeCodeIcon(isActive: isActive)
                results[i].displayAlias = isActive ? "当前" : nil
                rowsToReload.append(i)
            }
            reloadClaudeCodeRows(at: rowsToReload)

        case .contextPrompt:
            // 切换上下文预设
            guard
                let prompt = ContextPromptService.shared.prompts.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            do {
                try ContextPromptService.shared.switchPrompt(to: prompt, for: .codex)
            } catch {
                print("Codex Switcher: 切换上下文失败: \(error)")
            }
            // 就地更新所有上下文行的图标和状态
            let activePromptId = ContextPromptService.shared.currentCodexPrompt?.id
            var ctxRowsToReload: [Int] = []
            for i in results.indices {
                guard results[i].claudeCodeItemType == .contextPrompt,
                    let rowIdStr = results[i].claudeCodeItemId
                else { continue }
                let isActive = rowIdStr == activePromptId?.uuidString
                results[i].icon = makeClaudeCodeIcon(isActive: isActive)
                results[i].displayAlias = isActive ? "当前" : nil
                ctxRowsToReload.append(i)
            }
            reloadClaudeCodeRows(at: ctxRowsToReload)

        case .mcp:
            guard
                let server = ClaudeMcpService.shared.servers.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            let newEnabled = !server.isEnabled
            do {
                try ClaudeMcpService.shared.toggleEnabled(server)
            } catch {
                print("Codex Switcher: 切换 MCP 失败: \(error)")
            }
            if let rowIndex = results.firstIndex(where: {
                $0.claudeCodeItemId == itemUUID.uuidString
            }) {
                results[rowIndex].icon = makeClaudeCodeIcon(isActive: newEnabled)
                results[rowIndex].displayAlias = newEnabled ? "已启用" : "已禁用"
                reloadClaudeCodeRows(at: [rowIndex])
            }

        case .skill:
            guard
                let skill = ClaudeSkillService.shared.skills.first(where: {
                    $0.id == itemUUID
                })
            else { return }
            let newEnabled = !skill.isEnabled
            do {
                try ClaudeSkillService.shared.toggleEnabled(skill)
            } catch {
                print("Codex Switcher: 切换 Skill 失败: \(error)")
            }
            if let rowIndex = results.firstIndex(where: {
                $0.claudeCodeItemId == itemUUID.uuidString
            }) {
                results[rowIndex].icon = makeClaudeCodeIcon(isActive: newEnabled)
                results[rowIndex].displayAlias = newEnabled ? "已启用" : "已禁用"
                reloadClaudeCodeRows(at: [rowIndex])
            }
        }
    }

    /// 退出 Codex Switcher 模式
    func exitCodexMode() {
        guard isInCodexMode else { return }

        isInCodexMode = false

        restoreNormalModeUI()

        searchField.stringValue = ""
        setPlaceholder("搜索应用或文档...")
        resetState()
    }

}
