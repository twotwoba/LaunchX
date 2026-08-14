import AppKit

// MARK: - Utility Tools Extension

extension SearchPanelViewController {
    /// 加载 UUID 生成器
    func loadUUIDGenerator() {
        // 显示 UUID 选项视图
        uuidOptionsView.isHidden = false
        scrollView.isHidden = true
        divider.isHidden = false

        // 重置选项状态
        hyphenCheckbox.state = uuidUseHyphen ? .on : .off
        uppercaseRadio.state = uuidUppercase ? .on : .off
        lowercaseRadio.state = uuidUppercase ? .off : .on

        // 设置搜索框用于输入数量
        searchField.stringValue = ""
        setPlaceholder("1-1000")

        // 确保搜索框获取焦点
        view.window?.makeFirstResponder(searchField)

        // 生成初始 UUID
        generateUUIDs()

        // 更新窗口高度
        updateWindowHeight(expanded: true)
    }

    /// 生成 UUID 列表
    func generateUUIDs() {
        // 从搜索框获取数量
        let inputText = searchField.stringValue
        if let count = Int(inputText), count > 0, count <= 1000 {
            uuidCount = count
        } else if inputText.isEmpty {
            uuidCount = 1
        } else {
            uuidCount = min(max(1, Int(inputText) ?? 1), 1000)
        }

        // 生成 UUID
        generatedUUIDs = (0..<uuidCount).map { _ in
            var uuid = UUID().uuidString
            if !uuidUseHyphen {
                uuid = uuid.replacingOccurrences(of: "-", with: "")
            }
            if !uuidUppercase {
                uuid = uuid.lowercased()
            }
            return uuid
        }

        // 更新文本视图
        let text = generatedUUIDs.joined(separator: "\n")
        uuidResultTextView.string = text

        // 确保文本视图大小正确
        if let container = uuidResultTextView.textContainer,
            let layoutManager = uuidResultTextView.layoutManager
        {
            layoutManager.ensureLayout(for: container)
            let size = layoutManager.usedRect(for: container).size
            uuidResultTextView.setFrameSize(
                NSSize(
                    width: uuidResultView.contentSize.width,
                    height: max(size.height + 16, uuidResultView.contentSize.height)
                ))
        }
    }

    /// 复制所有 UUID 到剪贴板
    func copyAllUUIDs() {
        guard !generatedUUIDs.isEmpty else { return }
        let text = generatedUUIDs.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 关闭面板
        PanelManager.shared.hidePanel()
    }

    // MARK: - URL 编码解码方法

    /// 加载 URL 编码解码工具
    func loadURLCoder() {
        // 显示 URL 编码解码视图
        urlCoderView.isHidden = false
        scrollView.isHidden = true
        divider.isHidden = false

        // 清空输入框
        decodedURLTextView.string = ""
        encodedURLTextView.string = ""

        // 更新窗口高度
        updateWindowHeight(expanded: true)

        // 延迟让解码输入框获取焦点（确保窗口已显示）
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.decodedURLTextView)
        }
    }

    /// 处理解码输入框变化 - 编码 URL
    func encodeURL() {
        let decoded = decodedURLTextView.string
        if decoded.isEmpty {
            encodedURLTextView.string = ""
            return
        }
        // URL 编码
        if let encoded = decoded.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            encodedURLTextView.string = encoded
        }
    }

    /// 处理编码输入框变化 - 解码 URL
    func decodeURL() {
        let encoded = encodedURLTextView.string
        if encoded.isEmpty {
            decodedURLTextView.string = ""
            return
        }
        // URL 解码
        if let decoded = encoded.removingPercentEncoding {
            decodedURLTextView.string = decoded
        }
    }

    // MARK: - Base64 编码解码方法

    /// 加载 Base64 编码解码工具
    func loadBase64Coder() {
        // 显示 Base64 编码解码视图
        base64CoderView.isHidden = false
        scrollView.isHidden = true
        divider.isHidden = false

        // 清空输入框
        originalTextView.string = ""
        base64TextView.string = ""

        // 更新窗口高度
        updateWindowHeight(expanded: true)

        // 延迟让原始文本输入框获取焦点（确保窗口已显示）
        DispatchQueue.main.async { [weak self] in
            self?.view.window?.makeFirstResponder(self?.originalTextView)
        }
    }

    /// 处理原始文本变化 - 编码为 Base64
    func encodeBase64() {
        let original = originalTextView.string
        if original.isEmpty {
            base64TextView.string = ""
            return
        }
        // Base64 编码
        if let data = original.data(using: .utf8) {
            base64TextView.string = data.base64EncodedString()
        }
    }

    /// 处理 Base64 文本变化 - 解码为原始文本
    func decodeBase64() {
        let base64 = base64TextView.string
        if base64.isEmpty {
            originalTextView.string = ""
            return
        }
        // Base64 解码
        if let data = Data(base64Encoded: base64),
            let decoded = String(data: data, encoding: .utf8)
        {
            originalTextView.string = decoded
        }
    }

    /// 加载 IP 地址
    func loadIPAddresses() {
        // 设置 placeholder 提示用户操作
        searchField.stringValue = ""

        ipQueryResults = [
            (label: "本地 IP", ip: "加载中..."),
            (label: "公网 IP", ip: "加载中..."),
        ]
        reloadIPResults()

        // 获取本地 IP
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let localIP = self?.getLocalIPAddress() ?? "获取失败"
            DispatchQueue.main.async {
                guard let self = self, self.isInUtilityMode, self.currentUtilityIdentifier == "ip"
                else { return }
                if self.ipQueryResults.count > 0 {
                    self.ipQueryResults[0] = (label: "本地 IP", ip: localIP)
                    self.reloadIPResults()
                }
            }
        }

        // 获取公网 IP
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let publicIP = self?.getPublicIPAddress() ?? "获取失败"
            DispatchQueue.main.async {
                guard let self = self, self.isInUtilityMode, self.currentUtilityIdentifier == "ip"
                else { return }
                if self.ipQueryResults.count > 1 {
                    self.ipQueryResults[1] = (label: "公网 IP", ip: publicIP)
                    self.reloadIPResults()
                }
            }
        }
    }

    /// 刷新 IP 结果显示
    func reloadIPResults() {
        // 保存当前选中索引
        let currentSelection = selectedIndex

        // 将 IP 结果转换为 SearchResult 显示
        results = ipQueryResults.enumerated().map { index, item in
            let icon: NSImage
            // 根据原始标签判断图标类型（去除 "✓ 已复制" 后缀）
            let isLocalIP = item.label.hasPrefix("本地")
            if isLocalIP {
                icon =
                    NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage()
            } else {
                icon =
                    NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
            }
            icon.size = NSSize(width: 32, height: 32)

            return SearchResult(
                name: item.ip,
                path: item.label,
                icon: icon,
                isDirectory: false,
                displayAlias: item.label
            )
        }

        // 恢复选中索引
        if results.indices.contains(currentSelection) {
            selectedIndex = currentSelection
        } else {
            selectedIndex = 0
        }

        tableView.reloadData()

        // 确保选中行视觉更新
        if results.indices.contains(selectedIndex) {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        updateVisibility()
    }

    /// 获取本地 IP 地址
    func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // 只处理 IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // 排除 loopback 接口
                if name == "en0" || name == "en1" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    if address != nil && !address!.isEmpty {
                        break
                    }
                }
            }
        }

        return address
    }

    /// 获取公网 IP 地址
    func getPublicIPAddress() -> String? {
        // 优先使用国内 IP 查询服务，避免代理影响
        let services = [
            "https://myip.ipip.net/ip",
            "https://ip.3322.net",
            "https://www.taobao.com/help/getip.php",
            "https://api.ipify.org",
        ]

        for urlString in services {
            guard let url = URL(string: urlString) else { continue }

            let semaphore = DispatchSemaphore(value: 0)
            var result: String?

            var request = URLRequest(url: url)
            request.timeoutInterval = 3

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                defer { semaphore.signal() }
                guard error == nil,
                    let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 200,
                    let data = data,
                    let content = String(data: data, encoding: .utf8)
                else { return }

                // 解析不同服务的响应格式
                if urlString.contains("taobao") {
                    // 淘宝格式: ipCallback({ip:"x.x.x.x"})
                    if let range = content.range(of: "\"([0-9.]+)\"", options: .regularExpression) {
                        let ipWithQuotes = String(content[range])
                        result = ipWithQuotes.replacingOccurrences(of: "\"", with: "")
                    }
                } else {
                    // 其他服务直接返回 IP 或简单文本
                    let ip = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 验证是否是有效的 IP 地址格式
                    let ipPattern = "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$"
                    if ip.range(of: ipPattern, options: .regularExpression) != nil {
                        result = ip
                    }
                }
            }
            task.resume()

            // 等待最多 3 秒
            _ = semaphore.wait(timeout: .now() + 3)

            if let ip = result, !ip.isEmpty {
                return ip
            }
        }

        return nil
    }

    /// 处理实用工具模式下的回车操作
    func handleUtilityAction() {
        guard let identifier = currentUtilityIdentifier else { return }

        switch identifier {
        case "ip":
            // 复制选中的 IP 地址
            let currentIndex = selectedIndex  // 捕获当前索引
            guard ipQueryResults.indices.contains(currentIndex) else { return }
            let ip = ipQueryResults[currentIndex].ip
            if ip != "加载中..." && ip != "获取失败" {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)

                // 获取原始标签（不含 "✓ 已复制"）
                let originalLabel =
                    ipQueryResults[currentIndex].label.hasPrefix("本地") ? "本地 IP" : "公网 IP"

                // 显示复制成功提示
                ipQueryResults[currentIndex] = (label: "\(originalLabel) ✓ 已复制", ip: ip)
                reloadIPResults()

                // 1秒后恢复原标签
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self = self,
                        self.isInUtilityMode,
                        self.currentUtilityIdentifier == "ip"
                    else { return }
                    // 使用捕获的索引而非当前选中索引
                    if self.ipQueryResults.indices.contains(currentIndex) {
                        self.ipQueryResults[currentIndex] = (label: originalLabel, ip: ip)
                        self.reloadIPResults()
                    }
                }
            }
        case "kill":
            // 显示 kill 确认弹窗
            showKillConfirmation()
        case "uuid":
            // 复制所有 UUID
            copyAllUUIDs()
        default:
            break
        }
    }

    // MARK: - Kill 模式方法

    /// 加载 kill 模式的进程列表
    func loadKillModeProcesses() {
        // 设置 placeholder
        setPlaceholder("请输入关键词搜索")

        // 显示加载中状态
        results = []
        tableView.reloadData()

        // 异步加载进程列表
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = ProcessManager.shared.getRunningApps()
            let ports = ProcessManager.shared.getListeningPortProcesses()

            DispatchQueue.main.async {
                guard let self = self,
                    self.isInUtilityMode,
                    self.currentUtilityIdentifier == "kill"
                else { return }

                self.killModeApps = apps
                self.killModePorts = ports
                self.killModeAllItems = apps + ports
                self.killModeFilteredItems = self.killModeAllItems
                self.reloadKillModeResults()
            }
        }
    }

    /// 刷新 kill 模式结果显示
    func reloadKillModeResults() {
        let currentSelection = selectedIndex

        // 构建带分组标题的结果列表
        var newResults: [SearchResult] = []

        // 过滤已打开应用
        let filteredApps = killModeFilteredItems.filter { $0.isApp }
        // 过滤监听端口进程
        let filteredPorts = killModeFilteredItems.filter { !$0.isApp }

        // 添加「已打开应用」分组
        if !filteredApps.isEmpty {
            // 添加分组标题
            let headerResult = SearchResult(
                name: "已打开应用",
                path: "",
                icon: NSImage(),
                isDirectory: false,
                isSectionHeader: true
            )
            newResults.append(headerResult)

            // 添加应用列表
            for app in filteredApps {
                let icon =
                    app.icon ?? NSImage(
                        systemSymbolName: "app", accessibilityDescription: "App")!
                icon.size = NSSize(width: 32, height: 32)

                let result = SearchResult(
                    name: app.name,
                    path: "\(app.id)",  // 存储 PID
                    icon: icon,
                    isDirectory: false,
                    processStats: "|\(app.formattedCPU)|\(app.formattedMemory)"  // 格式: |cpu|memory (无端口)
                )
                newResults.append(result)
            }
        }

        // 添加「已监听端口」分组
        if !filteredPorts.isEmpty {
            // 添加分组标题
            let headerResult = SearchResult(
                name: "已打开监听端口",
                path: "",
                icon: NSImage(),
                isDirectory: false,
                isSectionHeader: true
            )
            newResults.append(headerResult)

            // 添加端口进程列表
            for process in filteredPorts {
                let icon =
                    process.icon ?? NSImage(
                        systemSymbolName: "terminal", accessibilityDescription: "Process")!
                icon.size = NSSize(width: 32, height: 32)

                // 端口号放到 processStats 前面，使用管道分隔
                let portStr = process.port != nil ? ":\(process.port!)" : ""
                let result = SearchResult(
                    name: process.name,
                    path: "\(process.id)",  // 存储 PID
                    icon: icon,
                    isDirectory: false,
                    processStats: "\(portStr)|\(process.formattedCPU)|\(process.formattedMemory)"  // 格式: port|cpu|memory
                )
                newResults.append(result)
            }
        }

        results = newResults

        // 恢复选中索引，跳过分组标题
        if results.indices.contains(currentSelection)
            && !results[currentSelection].isSectionHeader
        {
            selectedIndex = currentSelection
        } else {
            // 找到第一个非标题行
            selectedIndex = results.firstIndex { !$0.isSectionHeader } ?? 0
        }

        tableView.reloadData()

        if results.indices.contains(selectedIndex) {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
        }

        updateVisibility()
    }

    /// 执行 kill 模式搜索过滤
    func performKillModeSearch(_ query: String) {
        if query.isEmpty {
            killModeFilteredItems = killModeAllItems
        } else {
            let lowercaseQuery = query.lowercased()
            killModeFilteredItems = killModeAllItems.filter { process in
                // 匹配名称
                if process.name.lowercased().contains(lowercaseQuery) {
                    return true
                }
                // 匹配端口号
                if let port = process.port, "\(port)".contains(query) {
                    return true
                }
                // 匹配 PID
                if "\(process.id)".contains(query) {
                    return true
                }
                return false
            }
        }
        reloadKillModeResults()
    }

    /// 显示 kill 确认弹窗
    func showKillConfirmation() {
        guard selectedIndex < results.count else { return }
        let selectedResult = results[selectedIndex]

        // 跳过分组标题
        guard !selectedResult.isSectionHeader else { return }

        // 获取 PID
        guard let pid = Int32(selectedResult.path) else { return }

        // 查找对应的进程信息
        guard let processInfo = killModeAllItems.first(where: { $0.id == pid }) else { return }

        // 显示确认弹窗
        let alert = NSAlert()
        alert.messageText = "是否确定退出 \(processInfo.name)?"
        alert.informativeText = processInfo.isApp ? "" : "进程 ID: \(pid)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        // 设置图标
        if let icon = processInfo.icon {
            alert.icon = icon
        }

        // 激活应用以确保弹窗获得焦点并支持回车确认
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // 执行 kill
            let success: Bool
            if processInfo.isApp {
                success = ProcessManager.shared.terminateApp(pid: pid)
            } else {
                success = ProcessManager.shared.killProcess(pid: pid)
            }

            if success {
                // 从列表中移除
                killModeAllItems.removeAll { $0.id == pid }
                killModeFilteredItems.removeAll { $0.id == pid }
                killModeApps.removeAll { $0.id == pid }
                killModePorts.removeAll { $0.id == pid }
                reloadKillModeResults()
            } else {
                // 显示失败提示
                let failAlert = NSAlert()
                failAlert.messageText = "无法终止 \(processInfo.name)"
                failAlert.informativeText = "可能需要更高的权限"
                failAlert.alertStyle = .critical
                failAlert.addButton(withTitle: "确定")
                NSApp.activate(ignoringOtherApps: true)
                failAlert.runModal()
            }
        }
    }

    /// 滚动表格使选中行尽量保持在可视区域中间
    func scrollToKeepSelectionCentered() {
        guard selectedIndex >= 0 else { return }

        let visibleRect = scrollView.contentView.bounds
        let selectedRect = tableView.rect(ofRow: selectedIndex)

        // 计算目标滚动位置，使选中行在中间
        // targetY = 选中行中心点 - 可视区域高度的一半
        let targetY = selectedRect.midY - (visibleRect.height / 2)

        // 边界处理：确保不会滚动超出范围
        let maxY = max(0, tableView.frame.height - visibleRect.height)
        let clampedY = max(0, min(targetY, maxY))

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 加载最近使用的项目（支持所有工具类型）
    func loadRecentApps() {
        // ⚠️ 重要：添加新的扩展模式时，必须在此处添加检查，否则会在扩展模式下加载最近项目
        // 如果已经在扩展模式中，不加载最近项目
        if isInAnyExtensionMode {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items: [SearchResult] = []
            var addedKeys = Set<String>()

            // 获取工具配置用于查找别名等信息
            let config = ToolsConfig.load()

            // 1. 从 LRU 缓存获取最近使用的项目（最多 8 个）
            let recentItems = RecentAppsManager.shared.getRecentItems(limit: 8)

            for item in recentItems {
                guard !addedKeys.contains(item.uniqueKey) else { continue }

                if let result = self?.createSearchResultFromRecentItem(item, config: config) {
                    items.append(result)
                    addedKeys.insert(item.uniqueKey)
                }
            }

            // 2. 如果 LRU 记录不足 8 个，用默认应用补充
            if items.count < 8 {
                let defaultApps = [
                    "/System/Library/CoreServices/Finder.app",
                    "/System/Applications/System Settings.app",
                    "/System/Applications/Notes.app",
                    "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                    "/System/Applications/App Store.app",
                    "/System/Applications/Mail.app",
                    "/System/Applications/Calendar.app",
                    "/System/Applications/Messages.app",
                ]

                for path in defaultApps {
                    guard items.count < 8 else { break }
                    let key = "app:\(path)"
                    guard !addedKeys.contains(key) else { continue }
                    guard FileManager.default.fileExists(atPath: path) else { continue }

                    if let result = self?.createSearchResult(from: path) {
                        items.append(result)
                        addedKeys.insert(key)
                    }
                }
            }

            DispatchQueue.main.async {
                // ⚠️ 重要：添加新的扩展模式时，必须在此处添加检查，否则异步回调会覆盖扩展模式的结果
                // 再次检查是否在扩展模式，避免覆盖扩展模式的结果列表
                guard self?.isInAnyExtensionMode != true else {
                    return
                }

                self?.recentApps = items

                // 如果是 Full 模式且当前没有搜索内容，显示最近项目
                let defaultWindowMode =
                    UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"
                if defaultWindowMode == "full" && self?.searchField.stringValue.isEmpty == true {
                    self?.performSearch("")
                }
            }
        }
    }

    /// 从 RecentItem 创建 SearchResult
    func createSearchResultFromRecentItem(_ item: RecentItem, config: ToolsConfig)
        -> SearchResult?
    {
        switch item.type {
        case .app:
            return createSearchResult(from: item.identifier)

        case .webLink:
            // 查找对应的 ToolItem 获取完整信息
            if let tool = config.tools.first(where: {
                $0.type == .webLink && $0.url == item.identifier
            }) {
                let icon = tool.icon
                icon.size = NSSize(width: 32, height: 32)
                return SearchResult(
                    name: tool.name,
                    path: item.identifier,
                    icon: icon,
                    isDirectory: false,
                    displayAlias: tool.alias,
                    isWebLink: true,
                    supportsQueryExtension: tool.supportsQueryExtension,
                    defaultUrl: tool.defaultUrl
                )
            }
            return nil

        case .utility:
            // 查找对应的 ToolItem
            if let tool = config.tools.first(where: {
                $0.type == .utility && $0.extensionIdentifier == item.identifier
            }) {
                let icon = tool.icon
                icon.size = NSSize(width: 32, height: 32)
                return SearchResult(
                    name: tool.name,
                    path: item.identifier,
                    icon: icon,
                    isDirectory: false,
                    displayAlias: tool.alias,
                    isUtility: true,
                    supportsQueryExtension: true
                )
            }
            return nil

        case .systemCommand:
            // 查找对应的 ToolItem
            if let tool = config.tools.first(where: {
                $0.type == .systemCommand && $0.command == item.identifier
            }) {
                let icon = tool.icon
                icon.size = NSSize(width: 32, height: 32)
                return SearchResult(
                    name: tool.displayName,
                    path: item.identifier,
                    icon: icon,
                    isDirectory: false,
                    displayAlias: tool.alias,
                    isSystemCommand: true
                )
            }
            return nil
        }
    }

    /// 从路径创建 SearchResult
    func createSearchResult(from path: String) -> SearchResult? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let name = FileManager.default.getAppDisplayName(at: path)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: name,
            path: path,
            icon: icon,
            isDirectory: true
        )
    }

    @objc func tableViewDoubleClicked() {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0 && results.indices.contains(clickedRow) else { return }
        selectedIndex = clickedRow
        openSelected()
    }

    func openSelected() {
        // 网页直达 Query 模式：替换 {query} 占位符后打开
        // 注意：Tab 模式下 results 为空，需要优先处理
        if isInWebLinkQueryMode, let webLink = currentWebLinkResult {
            openWebLinkWithQuery(webLink: webLink)
            return
        }

        // 实用工具模式：执行对应操作
        if isInUtilityMode {
            handleUtilityAction()
            return
        }

        guard results.indices.contains(selectedIndex) else { return }
        let item = results[selectedIndex]

        // 提醒事项：点击切换完成状态，完成后自动收起面板
        if item.isReminder, let identifier = item.reminderIdentifier {
            RemindersService.shared.toggleCompletion(identifier: identifier) {
                [weak self] success in
                if success {
                    // 刷新提醒事项列表并隐藏面板
                    self?.loadReminders()
                    PanelManager.shared.hidePanel()
                }
            }
            return
        }

        // IDE 项目模式：使用对应 IDE 打开项目
        if isInIDEProjectMode, let ideApp = currentIDEApp {
            IDERecentProjectsService.shared.openProject(
                IDEProject(name: item.name, path: item.path, ideType: currentIDEType ?? .vscode),
                withIDEAt: ideApp.path
            )
            // 记录 IDE 应用到 LRU 缓存
            RecentAppsManager.shared.recordAppOpen(path: ideApp.path)
            PanelManager.shared.hidePanel()
            return
        }

        // 文件夹打开模式：使用选中的应用打开文件夹
        if isInFolderOpenMode, let folder = currentFolder {
            IDERecentProjectsService.shared.openFolder(folder.path, withApp: item.path)
            // 记录打开文件夹的应用到 LRU 缓存
            RecentAppsManager.shared.recordAppOpen(path: item.path)
            PanelManager.shared.hidePanel()
            return
        }

        // 网页直达：处理 {query} 占位符
        if item.isWebLink {
            var finalUrl = item.path

            // 如果支持 query 扩展，需要处理 {query} 占位符
            if item.supportsQueryExtension {
                // 获取当前搜索框中的文本作为查询
                let currentQuery = searchField.stringValue.trimmingCharacters(in: .whitespaces)

                if !currentQuery.isEmpty {
                    // 有搜索文本，用它替换 {query} 占位符
                    let encodedQuery =
                        currentQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                        ?? currentQuery
                    finalUrl = item.path.replacingOccurrences(of: "{query}", with: encodedQuery)
                } else if let defaultUrl = item.defaultUrl, !defaultUrl.isEmpty {
                    // 没有搜索文本但有默认 URL，直接跳转到默认 URL
                    finalUrl = defaultUrl
                } else {
                    // 没有搜索文本也没有默认 URL，去掉 {query} 占位符
                    finalUrl = item.path.replacingOccurrences(of: "{query}", with: "")
                }
            }

            if let url = URL(string: finalUrl) {
                NSWorkspace.shared.open(url)
                // 记录到 LRU 缓存
                RecentAppsManager.shared.recordWebLinkOpen(url: item.path, name: item.name)
            }
            PanelManager.shared.hidePanel()
            return
        }

        // 系统命令：执行对应的系统操作
        if item.isSystemCommand {
            // 记录到 LRU 缓存
            RecentAppsManager.shared.recordSystemCommandOpen(command: item.path, name: item.name)
            // 先隐藏面板，避免弹窗被遮挡
            PanelManager.shared.hidePanel()
            // 执行系统命令（path 存储的是命令标识符）
            SystemCommandService.shared.execute(identifier: item.path) { success in
                if success {
                    print(
                        "SearchPanelViewController: System command '\(item.path)' executed successfully"
                    )
                } else {
                    print(
                        "SearchPanelViewController: System command '\(item.path)' failed or was cancelled"
                    )
                }
            }
            return
        }

        // 实用工具：进入扩展模式
        if item.isUtility {
            // 记录到 LRU 缓存
            RecentAppsManager.shared.recordUtilityOpen(identifier: item.path, name: item.name)
            // 通过搜索结果中的 path 获取工具信息
            let toolsConfig = ToolsConfig.load()
            if let tool = toolsConfig.enabledTools.first(where: {
                $0.extensionIdentifier == item.path
            }) {
                PanelManager.shared.showPanelInUtilityMode(tool: tool)
            }
            return
        }

        // 书签入口：进入书签搜索模式
        if item.isBookmarkEntry {
            enterBookmarkMode()
            return
        }

        // 2FA 入口：进入 2FA 搜索模式
        if item.is2FAEntry {
            enter2FAMode()
            return
        }

        // Claude Code 入口：进入 Claude Code Switcher 模式
        if item.isClaudeCodeEntry {
            enterClaudeCodeMode()
            return
        }

        // Codex 入口：进入 Codex Switcher 模式
        if item.isCodexEntry {
            enterCodexMode()
            return
        }

        // 股票面板入口：打开股票面板
        if item.isStockEntry {
            PanelManager.shared.hidePanel()
            StockPanelManager.shared.showPanel()
            return
        }

        // Claude Code 模式：处理选中项（切换 Provider/MCP/Skill）
        if isInClaudeCodeMode, item.isClaudeCodeItem {
            handleClaudeCodeItemSelected(item)
            return
        }

        // Codex 模式：处理选中项（切换 Provider/MCP/Skill）
        if isInCodexMode, item.isClaudeCodeItem {
            handleCodexItemSelected(item)
            return
        }

        // 书签：打开书签 URL
        if item.isBookmark {
            BookmarkService.shared.open(
                BookmarkItem(
                    title: item.name,
                    url: item.path,
                    source: item.bookmarkSource == "Chrome" ? .chrome : .safari
                ))
            PanelManager.shared.hidePanel()
            return
        }

        // 2FA 验证码：复制到剪贴板
        if item.is2FACode {
            // 从 twoFAResults 中找到对应的验证码
            if let codeItem = twoFAResults.first(where: { "验证码: \($0.code)" == item.name }) {
                codeItem.copyToClipboard()

                // 如果设置了复制后删除短信，则从列表移除并删除短信
                let settings = TwoFactorAuthSettings.load()
                if settings.deleteAfterCopy {
                    // 从列表中移除并刷新界面
                    twoFAResults.removeAll { $0.messageRowId == codeItem.messageRowId }
                    results.removeAll { $0.name == item.name }
                    tableView.reloadData()

                    // 更新选中状态
                    if !results.isEmpty {
                        selectedIndex = min(selectedIndex, results.count - 1)
                        tableView.selectRowIndexes(
                            IndexSet(integer: selectedIndex), byExtendingSelection: false)
                    }

                    // 异步删除短信（不阻塞 UI）
                    let rowId = codeItem.messageRowId
                    DispatchQueue.global(qos: .background).async {
                        _ = TwoFactorAuthService.shared.deleteMessage(rowId: rowId)
                    }
                }
            }
            PanelManager.shared.hidePanel()
            return
        }

        // 普通模式：使用默认应用打开
        let url = URL(fileURLWithPath: item.path)

        // 记录到 LRU 缓存（仅记录 .app 应用）
        if item.path.hasSuffix(".app") {
            RecentAppsManager.shared.recordAppOpen(path: item.path)
        }

        // 先隐藏面板，再异步打开 app（避免权限弹窗阻塞面板关闭）
        PanelManager.shared.hidePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSWorkspace.shared.open(url)
        }
    }
}
