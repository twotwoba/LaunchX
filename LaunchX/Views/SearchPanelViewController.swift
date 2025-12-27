import Cocoa

/// Pure AppKit implementation of the search panel - no SwiftUI overhead
class SearchPanelViewController: NSViewController {

    // MARK: - UI Components
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let divider = NSBox()
    private let noResultsLabel = NSTextField(labelWithString: "No results found.")

    // IDE 项目模式 UI
    private let ideTagView = NSView()
    private let ideIconView = NSImageView()
    private let ideNameLabel = NSTextField(labelWithString: "")

    // MARK: - State
    private var results: [SearchResult] = []
    private var recentApps: [SearchResult] = []  // 最近使用的应用
    private var selectedIndex: Int = 0
    private let searchEngine = SearchEngine.shared
    private var isShowingRecents: Bool = false  // 是否正在显示最近使用

    // IDE 项目模式状态
    private var isInIDEProjectMode: Bool = false
    private var currentIDEApp: SearchResult? = nil
    private var currentIDEType: IDEType? = nil
    private var ideProjects: [IDEProject] = []
    private var filteredIDEProjects: [IDEProject] = []

    // 文件夹打开方式选择模式状态
    private var isInFolderOpenMode: Bool = false
    private var currentFolder: SearchResult? = nil
    private var folderOpeners: [IDERecentProjectsService.FolderOpenerApp] = []

    // 网页直达 Query 模式状态
    private var isInWebLinkQueryMode: Bool = false
    private var currentWebLinkResult: SearchResult? = nil

    // MARK: - Constants
    private let rowHeight: CGFloat = 44
    private let headerHeight: CGFloat = 80

    // Placeholder 样式
    private func setPlaceholder(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 22, weight: .light),
        ]
        searchField.placeholderAttributedString = NSAttributedString(
            string: text, attributes: attributes)
    }

    // 用于 IDE 模式切换的约束
    private var searchFieldLeadingToIcon: NSLayoutConstraint?
    private var searchFieldLeadingToTag: NSLayoutConstraint?

    // MARK: - Lifecycle

    override func loadView() {
        // macOS 26+ 使用 Liquid Glass 效果
        if #available(macOS 26.0, *) {
            let glassEffectView = NSGlassEffectView()
            glassEffectView.style = .clear
            glassEffectView.tintColor = NSColor(named: "PanelBackgroundColor")
            glassEffectView.wantsLayer = true
            glassEffectView.layer?.cornerRadius = 26
            glassEffectView.layer?.masksToBounds = true
            self.view = glassEffectView
            return
        }

        // macOS 26 以下使用传统的 NSVisualEffectView
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .sidebar
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 26
        visualEffectView.layer?.masksToBounds = true

        self.view = visualEffectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("SearchPanelViewController: viewDidLoad called")
        setupUI()
        setupKeyboardMonitor()
        setupNotificationObservers()

        // SearchEngine handles indexing automatically on init
        // Just trigger a reference to ensure it starts
        _ = searchEngine.isReady

        // 加载最近使用的应用
        loadRecentApps()

        // Register for panel show callback to refresh recent apps
        PanelManager.shared.onWillShow = { [weak self] in
            self?.loadRecentApps()
        }

        // Register for panel hide callback
        PanelManager.shared.onWillHide = { [weak self] in
            self?.resetState()
        }
    }

    /// 设置通知观察者
    private func setupNotificationObservers() {
        // 监听直接进入 IDE 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterIDEModeDirectly(_:)),
            name: .enterIDEModeDirectly,
            object: nil
        )
    }

    /// 处理直接进入 IDE 模式的通知
    @objc private func handleEnterIDEModeDirectly(_ notification: Notification) {
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
        selectedIndex = 0
        searchField.stringValue = ""
        setPlaceholder("搜索项目...")
        tableView.reloadData()
        updateVisibility()

        print("SearchPanelViewController: IDE mode setup complete, results count=\(results.count)")
    }

    // MARK: - Setup

    private func setupUI() {
        // IDE Tag View (用于 IDE 项目模式)
        ideTagView.wantsLayer = true
        ideTagView.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        ideTagView.layer?.cornerRadius = 6
        ideTagView.translatesAutoresizingMaskIntoConstraints = false
        ideTagView.isHidden = true
        view.addSubview(ideTagView)

        ideIconView.translatesAutoresizingMaskIntoConstraints = false
        ideTagView.addSubview(ideIconView)

        ideNameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        ideNameLabel.textColor = .labelColor
        ideNameLabel.translatesAutoresizingMaskIntoConstraints = false
        ideTagView.addSubview(ideNameLabel)

        // Search icon (隐藏，不再显示)
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.isHidden = true
        view.addSubview(searchIcon)

        // Search field
        setPlaceholder("搜索应用或文档...")
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 22, weight: .light)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

        // Divider
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true
        view.addSubview(divider)

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
        view.addSubview(scrollView)

        // No results label
        noResultsLabel.textColor = .secondaryLabelColor
        noResultsLabel.alignment = .center
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.isHidden = true
        view.addSubview(noResultsLabel)

        // Constraints
        NSLayoutConstraint.activate([
            // IDE Tag View - 与搜索框垂直居中对齐，微调 +3 补偿视觉偏差
            ideTagView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
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
            searchIcon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            searchIcon.centerYAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            searchIcon.widthAnchor.constraint(equalToConstant: 22),
            searchIcon.heightAnchor.constraint(equalToConstant: 22),

            // Search field (leading 约束单独处理，用于 IDE 模式切换)
            searchField.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -20),
            searchField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            // Divider
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.topAnchor.constraint(equalTo: view.topAnchor, constant: headerHeight),

            // Scroll view
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // No results label
            noResultsLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            noResultsLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 20),
        ])

        // 创建并保存 searchField 的 leading 约束
        // 默认直接从左边开始（无搜索图标）
        searchFieldLeadingToIcon = searchField.leadingAnchor.constraint(
            equalTo: view.leadingAnchor, constant: 20)
        searchFieldLeadingToTag = searchField.leadingAnchor.constraint(
            equalTo: ideTagView.trailingAnchor, constant: 12)
        searchFieldLeadingToIcon?.isActive = true
    }

    private var keyboardMonitor: Any?

    private func setupKeyboardMonitor() {
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

    deinit {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Public Methods

    func focus() {
        view.window?.makeFirstResponder(searchField)

        // 每次显示面板时刷新状态，确保设置更改立即生效
        refreshDisplayMode()
    }

    /// 刷新显示模式（Simple/Full）
    private func refreshDisplayMode() {
        // 如果在 IDE 项目模式或文件夹模式，不要覆盖当前显示的结果
        if isInIDEProjectMode || isInFolderOpenMode {
            updateVisibility()
            return
        }

        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"

        if searchField.stringValue.isEmpty {
            if defaultWindowMode == "full" && !recentApps.isEmpty {
                results = recentApps
                isShowingRecents = true
            } else {
                results = []
                isShowingRecents = false
            }
            selectedIndex = 0
            tableView.reloadData()
        }

        updateVisibility()
    }

    func resetState() {
        // 如果在 IDE 项目模式，先恢复普通模式 UI
        if isInIDEProjectMode {
            isInIDEProjectMode = false
            currentIDEApp = nil
            currentIDEType = nil
            ideProjects = []
            filteredIDEProjects = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")
        }

        // 如果在文件夹打开模式，先恢复普通模式 UI
        if isInFolderOpenMode {
            isInFolderOpenMode = false
            currentFolder = nil
            folderOpeners = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")
        }

        searchField.stringValue = ""
        selectedIndex = 0

        // Full 模式下显示最近使用的应用
        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"
        if defaultWindowMode == "full" && !recentApps.isEmpty {
            results = recentApps
            isShowingRecents = true
        } else {
            results = []
            isShowingRecents = false
        }

        tableView.reloadData()
        updateVisibility()
    }

    // MARK: - Search

    private func performSearch(_ query: String) {
        guard !query.isEmpty else {
            selectedIndex = 0

            // Full 模式下显示最近使用的应用
            let defaultWindowMode =
                UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"
            if defaultWindowMode == "full" && !recentApps.isEmpty {
                results = recentApps
                isShowingRecents = true
            } else {
                results = []
                isShowingRecents = false
            }

            tableView.reloadData()
            updateVisibility()
            return
        }

        isShowingRecents = false
        let searchResults = searchEngine.searchSync(text: query)
        results = searchResults
        selectedIndex = results.isEmpty ? 0 : 0
        tableView.reloadData()
        updateVisibility()

        if !results.isEmpty {
            tableView.selectRowIndexes(
                IndexSet(integer: selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedIndex)
        }
    }

    private func updateVisibility() {
        let hasQuery = !searchField.stringValue.isEmpty
        let hasResults = !results.isEmpty
        let defaultWindowMode =
            UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"

        divider.isHidden = !hasQuery && !isShowingRecents
        scrollView.isHidden = !hasResults
        noResultsLabel.isHidden = !hasQuery || hasResults

        // Update window height
        if defaultWindowMode == "full" {
            // Full 模式：始终展开
            updateWindowHeight(expanded: true)
        } else {
            // Simple 模式：有搜索内容且有结果时展开
            updateWindowHeight(expanded: hasQuery && hasResults)
        }
    }

    private func updateWindowHeight(expanded: Bool) {
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

        let targetHeight: CGFloat = shouldExpand ? 500 : 80
        let currentFrame = window.frame

        guard abs(currentFrame.height - targetHeight) > 1 else { return }

        let newOriginY = currentFrame.origin.y - (targetHeight - currentFrame.height)
        let newFrame = NSRect(
            x: currentFrame.origin.x,
            y: newOriginY,
            width: currentFrame.width,
            height: targetHeight
        )

        // No animation for speed
        window.setFrame(newFrame, display: true, animate: false)
    }

    // MARK: - Keyboard Handling

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // 检查输入法是否正在组合输入（如中文输入法）
        var isComposing = false
        if let fieldEditor = searchField.currentEditor() as? NSTextView {
            isComposing = fieldEditor.markedRange().length > 0
        }

        switch Int(event.keyCode) {
        case 51:  // Delete - IDE 项目模式、文件夹打开模式或网页直达 Query 模式下，输入框为空时退出
            if isComposing { return event }
            if (isInIDEProjectMode || isInFolderOpenMode || isInWebLinkQueryMode)
                && searchField.stringValue.isEmpty
            {
                if isInIDEProjectMode {
                    exitIDEProjectMode()
                } else if isInFolderOpenMode {
                    exitFolderOpenMode()
                } else {
                    exitWebLinkQueryMode()
                }
                return nil
            }
            return event
        case 48:  // Tab - 进入 IDE 项目模式、文件夹打开模式或网页直达 Query 模式
            if isComposing { return event }
            if !isInIDEProjectMode && !isInFolderOpenMode && !isInWebLinkQueryMode {
                // 检查当前选中项是否有扩展功能
                guard results.indices.contains(selectedIndex) else {
                    // 没有选中任何项目，忽略 Tab 键
                    return nil
                }
                let item = results[selectedIndex]

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
            PanelManager.shared.hidePanel()
            return nil
        case 36:  // Return
            if isComposing { return event }  // 让输入法确认输入
            openSelected()
            return nil
        default:
            // Ctrl+N / Ctrl+P
            if event.modifierFlags.contains(.control) {
                if event.keyCode == 45 {  // N
                    moveSelectionDown()
                    return nil
                } else if event.keyCode == 35 {  // P
                    moveSelectionUp()
                    return nil
                }
            }
            return event
        }
    }

    private func moveSelectionDown() {
        guard !results.isEmpty else { return }
        selectedIndex = min(selectedIndex + 1, results.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        scrollToKeepSelectionCentered()
        tableView.reloadData()
    }

    private func moveSelectionUp() {
        guard !results.isEmpty else { return }
        selectedIndex = max(selectedIndex - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        scrollToKeepSelectionCentered()
        tableView.reloadData()
    }

    // MARK: - IDE Project Mode

    /// 尝试进入 IDE 项目模式
    /// - Returns: 是否成功进入
    private func tryEnterIDEProjectMode() -> Bool {
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
    private func exitIDEProjectMode() {
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
    private func updateIDEModeUI() {
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
    private func restoreNormalModeUI() {
        // 隐藏 IDE/文件夹 标签
        ideTagView.isHidden = true

        // 切换 searchField 的 leading 约束
        searchFieldLeadingToTag?.isActive = false
        searchFieldLeadingToIcon?.isActive = true
    }

    /// IDE 项目模式下的搜索
    private func performIDEProjectSearch(_ query: String) {
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
    private func tryEnterFolderOpenMode() -> Bool {
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
    private func exitFolderOpenMode() {
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
    private func updateFolderModeUI() {
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
    private func performFolderOpenerSearch(_ query: String) {
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
    private func tryEnterWebLinkQueryMode(for item: SearchResult) -> Bool {
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
    private func exitWebLinkQueryMode() {
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
    private func updateWebLinkQueryModeUI() {
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
    private func openWebLinkWithQuery(webLink: SearchResult) {
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
            NSWorkspace.shared.open(url)
        }

        exitWebLinkQueryMode()
        PanelManager.shared.hidePanel()
    }

    /// 滚动表格使选中行尽量保持在可视区域中间
    private func scrollToKeepSelectionCentered() {
        let visibleRect = scrollView.contentView.bounds

        // 计算可视区域能显示多少行
        let visibleRows = Int(visibleRect.height / rowHeight)
        let middleOffset = visibleRows / 2

        // 计算目标滚动位置，使选中行在中间
        let targetRow = max(0, selectedIndex - middleOffset)
        let targetRect = tableView.rect(ofRow: targetRow)

        // 如果选中行在前几行，不需要居中（保持在顶部）
        if selectedIndex < middleOffset {
            tableView.scrollRowToVisible(0)
        }
        // 如果选中行在最后几行，不需要居中（保持在底部）
        else if selectedIndex >= results.count - middleOffset {
            tableView.scrollRowToVisible(results.count - 1)
        }
        // 否则滚动使选中行居中
        else {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetRect.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// 加载最近使用的应用
    private func loadRecentApps() {
        // 如果已经在 IDE 项目模式、文件夹打开模式或网页直达 Query 模式，不加载最近应用
        if isInIDEProjectMode || isInFolderOpenMode || isInWebLinkQueryMode {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var apps: [SearchResult] = []
            var addedPaths = Set<String>()

            // 1. 优先从 LRU 缓存获取最近使用的应用
            let lruPaths = RecentAppsManager.shared.getRecentApps(limit: 8)
            for path in lruPaths {
                guard !addedPaths.contains(path) else { continue }
                if let result = self?.createSearchResult(from: path) {
                    apps.append(result)
                    addedPaths.insert(path)
                }
            }

            // 2. 如果 LRU 记录不足，用默认应用补充
            if apps.count < 8 {
                let defaultApps = [
                    "/System/Library/CoreServices/Finder.app",
                    "/System/Applications/System Settings.app",
                    "/System/Applications/App Store.app",
                    "/System/Applications/Notes.app",
                    "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
                    "/System/Applications/Mail.app",
                    "/System/Applications/Calendar.app",
                    "/System/Applications/Weather.app",
                ]

                for path in defaultApps {
                    guard apps.count < 8 else { break }
                    guard !addedPaths.contains(path) else { continue }
                    guard FileManager.default.fileExists(atPath: path) else { continue }

                    if let result = self?.createSearchResult(from: path) {
                        apps.append(result)
                        addedPaths.insert(path)
                    }
                }
            }

            DispatchQueue.main.async {
                // 再次检查是否在特殊模式，避免覆盖 IDE 项目列表
                guard
                    self?.isInIDEProjectMode != true && self?.isInFolderOpenMode != true
                        && self?.isInWebLinkQueryMode != true
                else {
                    return
                }

                self?.recentApps = apps

                // 如果是 Full 模式且当前没有搜索内容，显示最近应用
                let defaultWindowMode =
                    UserDefaults.standard.string(forKey: "defaultWindowMode") ?? "full"
                if defaultWindowMode == "full" && self?.searchField.stringValue.isEmpty == true {
                    self?.results = apps
                    self?.isShowingRecents = true
                    self?.tableView.reloadData()
                    self?.updateVisibility()
                }
            }
        }
    }

    /// 从路径创建 SearchResult
    private func createSearchResult(from path: String) -> SearchResult? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let name = FileManager.default.displayName(atPath: path)
            .replacingOccurrences(of: ".app", with: "")
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            name: name,
            path: path,
            icon: icon,
            isDirectory: true
        )
    }

    @objc private func tableViewDoubleClicked() {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0 && results.indices.contains(clickedRow) else { return }
        selectedIndex = clickedRow
        openSelected()
    }

    private func openSelected() {
        // 网页直达 Query 模式：替换 {query} 占位符后打开
        // 注意：Tab 模式下 results 为空，需要优先处理
        if isInWebLinkQueryMode, let webLink = currentWebLinkResult {
            openWebLinkWithQuery(webLink: webLink)
            return
        }

        guard results.indices.contains(selectedIndex) else { return }
        let item = results[selectedIndex]

        // IDE 项目模式：使用对应 IDE 打开项目
        if isInIDEProjectMode, let ideApp = currentIDEApp {
            IDERecentProjectsService.shared.openProject(
                IDEProject(name: item.name, path: item.path, ideType: currentIDEType ?? .vscode),
                withIDEAt: ideApp.path
            )
            PanelManager.shared.hidePanel()
            return
        }

        // 文件夹打开模式：使用选中的应用打开文件夹
        if isInFolderOpenMode, let folder = currentFolder {
            IDERecentProjectsService.shared.openFolder(folder.path, withApp: item.path)
            PanelManager.shared.hidePanel()
            return
        }

        // 网页直达：处理 {query} 占位符
        if item.isWebLink {
            var finalUrl = item.path

            // 如果支持 query 扩展，需要处理 {query} 占位符
            if item.supportsQueryExtension {
                if let defaultUrl = item.defaultUrl, !defaultUrl.isEmpty {
                    // 有默认 URL，直接跳转到默认 URL
                    finalUrl = defaultUrl
                } else {
                    // 没有默认 URL，去掉 {query} 占位符
                    finalUrl = item.path.replacingOccurrences(of: "{query}", with: "")
                }
            }

            if let url = URL(string: finalUrl) {
                NSWorkspace.shared.open(url)
            }
            PanelManager.shared.hidePanel()
            return
        }

        // 普通模式：使用默认应用打开
        let url = URL(fileURLWithPath: item.path)
        NSWorkspace.shared.open(url)

        // 记录到 LRU 缓存（仅记录 .app 应用）
        if item.path.hasSuffix(".app") {
            RecentAppsManager.shared.recordAppOpen(path: item.path)
        }

        PanelManager.shared.hidePanel()
    }
}

// MARK: - NSTextFieldDelegate

extension SearchPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue

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

        // 普通模式：搜索应用和文件
        performSearch(query)
    }
}

// MARK: - NSTableViewDataSource

extension SearchPanelViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return results.count
    }
}

// MARK: - NSTableViewDelegate

extension SearchPanelViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let identifier = NSUserInterfaceItemIdentifier("ResultCell")

        var cellView =
            tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCellView
        if cellView == nil {
            cellView = ResultCellView()
            cellView?.identifier = identifier
        }

        let item = results[row]
        let isSelected = row == selectedIndex
        // 在文件夹打开模式或 IDE 项目模式下隐藏箭头（不能再 Tab）
        cellView?.configure(
            with: item, isSelected: isSelected, hideArrow: isInFolderOpenMode || isInIDEProjectMode)

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < results.count {
            selectedIndex = row
            tableView.reloadData()
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }
}

// MARK: - Result Cell View

class ResultCellView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let aliasLabel = NSTextField(labelWithString: "")  // 别名标签
    private let aliasBadgeView = NSView()  // 别名背景视图
    private let pathLabel = NSTextField(labelWithString: "")
    private let backgroundView = NSView()
    private let arrowIndicator = NSImageView()  // IDE 箭头指示器

    // 用于切换 nameLabel 位置的约束
    private var nameLabelTopConstraint: NSLayoutConstraint!
    private var nameLabelCenterYConstraint: NSLayoutConstraint!
    private var nameLabelTrailingToArrow: NSLayoutConstraint!
    private var nameLabelTrailingToEdge: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Background
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 4
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Icon
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(nameLabel)

        // Alias badge background (圆角背景) - 紧跟在名称后面
        aliasBadgeView.wantsLayer = true
        aliasBadgeView.layer?.cornerRadius = 4
        aliasBadgeView.layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(0.25).cgColor
        aliasBadgeView.translatesAutoresizingMaskIntoConstraints = false
        aliasBadgeView.isHidden = true
        addSubview(aliasBadgeView)

        // Alias label
        aliasLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        aliasLabel.textColor = .secondaryLabelColor
        aliasLabel.translatesAutoresizingMaskIntoConstraints = false
        aliasLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(aliasLabel)

        // Path
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        // Arrow indicator for IDE apps
        arrowIndicator.image = NSImage(
            systemSymbolName: "arrow.right.to.line",
            accessibilityDescription: "Tab to open projects")
        arrowIndicator.contentTintColor = .secondaryLabelColor
        arrowIndicator.translatesAutoresizingMaskIntoConstraints = false
        arrowIndicator.isHidden = true
        addSubview(arrowIndicator)

        // 创建布局约束
        nameLabelTopConstraint = nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6)
        nameLabelCenterYConstraint = nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        // 名称的 trailing 约束（用于没有别名时限制宽度）
        nameLabelTrailingToArrow = nameLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: arrowIndicator.leadingAnchor, constant: -8)
        nameLabelTrailingToEdge = nameLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor, constant: -20)

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabelTopConstraint,

            // Alias badge - 紧跟在名称后面
            aliasBadgeView.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            aliasBadgeView.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            aliasLabel.leadingAnchor.constraint(equalTo: aliasBadgeView.leadingAnchor, constant: 6),
            aliasLabel.trailingAnchor.constraint(
                equalTo: aliasBadgeView.trailingAnchor, constant: -6),
            aliasLabel.topAnchor.constraint(equalTo: aliasBadgeView.topAnchor, constant: 2),
            aliasLabel.bottomAnchor.constraint(equalTo: aliasBadgeView.bottomAnchor, constant: -2),

            // Arrow indicator
            arrowIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            arrowIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowIndicator.widthAnchor.constraint(equalToConstant: 16),
            arrowIndicator.heightAnchor.constraint(equalToConstant: 16),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])
    }

    func configure(with item: SearchResult, isSelected: Bool, hideArrow: Bool = false) {
        iconView.image = item.icon
        nameLabel.stringValue = item.name

        // 显示别名标签（badge 样式，紧跟在名称后面）
        if let alias = item.displayAlias, !alias.isEmpty {
            aliasLabel.stringValue = alias
            aliasBadgeView.isHidden = false
        } else {
            aliasLabel.stringValue = ""
            aliasBadgeView.isHidden = true
        }

        // App 和网页直达只显示名称（垂直居中、字体大），文件和文件夹显示路径
        let isApp = item.path.hasSuffix(".app")
        let isWebLink = item.isWebLink
        let showPathLabel = !isApp && !isWebLink
        pathLabel.isHidden = !showPathLabel
        pathLabel.stringValue = showPathLabel ? item.path : ""

        // 检测是否为支持的 IDE、文件夹或网页直达 Query 扩展，显示箭头指示器
        // hideArrow 为 true 时强制隐藏（如文件夹打开模式下）
        let isIDE = IDEType.detect(from: item.path) != nil
        let isFolder = item.isDirectory && !isApp
        let isQueryWebLink = item.isWebLink && item.supportsQueryExtension
        let showArrow = !hideArrow && (isIDE || isFolder || isQueryWebLink)
        arrowIndicator.isHidden = !showArrow

        // 切换 nameLabel trailing 约束
        if showArrow {
            nameLabelTrailingToEdge.isActive = false
            nameLabelTrailingToArrow.isActive = true
        } else {
            nameLabelTrailingToArrow.isActive = false
            nameLabelTrailingToEdge.isActive = true
        }

        // 切换布局：App 和网页直达垂直居中，其他顶部对齐
        if isApp || isWebLink {
            nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
            nameLabelTopConstraint.isActive = false
            nameLabelCenterYConstraint.isActive = true
        } else {
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabelCenterYConstraint.isActive = false
            nameLabelTopConstraint.isActive = true
        }

        if isSelected {
            backgroundView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            nameLabel.textColor = .white
            pathLabel.textColor = .white.withAlphaComponent(0.8)
            arrowIndicator.contentTintColor = .white.withAlphaComponent(0.8)
            // 别名标签在选中时的样式
            aliasLabel.textColor = .white.withAlphaComponent(0.9)
            aliasBadgeView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        } else {
            backgroundView.layer?.backgroundColor = NSColor.clear.cgColor
            nameLabel.textColor = .labelColor
            pathLabel.textColor = .secondaryLabelColor
            arrowIndicator.contentTintColor = .secondaryLabelColor
            // 别名标签在未选中时的样式
            aliasLabel.textColor = .secondaryLabelColor
            aliasBadgeView.layer?.backgroundColor =
                NSColor.systemGray.withAlphaComponent(0.25).cgColor
        }
    }
}
