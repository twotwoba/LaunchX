import Cocoa

// MARK: - Panel Mode State Machine

/// 面板模式状态机 — 用单一枚举替代 8 个布尔标志，杜绝状态组合爆炸
enum PanelMode: Equatable {
    case search                          // 普通搜索
    case ideProject(path: String, type: IDEType)  // IDE 项目浏览
    case folderOpen(folder: SearchResult) // 文件夹打开方式
    case webLinkQuery(result: SearchResult) // 网页直达 Query
    case utility(identifier: String)     // 实用工具
    case bookmark                        // 书签搜索
    case twoFactorAuth                   // 2FA 验证码
    case claudeCode                      // Claude Code Switcher
    case codex                           // Codex Switcher

    /// 是否不是普通搜索模式
    var isExtensionMode: Bool {
        if case .search = self { return false }
        return true
    }
}

/// Pure AppKit implementation of the search panel - no SwiftUI overhead
class SearchPanelViewController: NSViewController {

    // MARK: - UI Components
    var contentView: NSView!  // 用于添加子视图的内容视图
    var visualEffectView: NSVisualEffectView?
    var glassEffectView: NSView?
    let searchField = NSTextField()
    let searchIcon = NSImageView()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    let divider = NSBox()
    let noResultsLabel = NSTextField(labelWithString: "No results found.")

    // 底部快捷键提示栏
    let shortcutHintView = NSView()
    let shortcutHintLabel = NSTextField(labelWithString: "")

    // IDE 项目模式 UI
    let ideTagView = NSView()
    let ideIconView = NSImageView()
    let ideNameLabel = NSTextField(labelWithString: "")

    // MARK: - State
    var results: [SearchResult] = []
    var contentHeightConstraint: NSLayoutConstraint?
    var recentApps: [SearchResult] = []  // 最近使用的应用
    var selectedIndex: Int = 0
    let searchEngine = SearchEngine.shared
    var isShowingRecents: Bool = false  // 是否正在显示最近使用

    /// 当前面板模式（从旧布尔标志派生的只读视图，用于 resetState 集中清理）
    var currentMode: PanelMode {
        if isInIDEProjectMode {
            return .ideProject(path: currentIDEApp?.path ?? "", type: currentIDEType ?? .vscode)
        }
        if isInFolderOpenMode, let folder = currentFolder {
            return .folderOpen(folder: folder)
        }
        if isInWebLinkQueryMode, let result = currentWebLinkResult {
            return .webLinkQuery(result: result)
        }
        if isInUtilityMode {
            return .utility(identifier: currentUtilityIdentifier ?? "")
        }
        if isInBookmarkMode { return .bookmark }
        if isIn2FAMode { return .twoFactorAuth }
        if isInClaudeCodeMode { return .claudeCode }
        if isInCodexMode { return .codex }
        return .search
    }

    /// 是否处于任何扩展模式（代理到状态机）
    var isInAnyExtensionMode: Bool { currentMode.isExtensionMode }

    // MARK: - 旧布尔标志（保留为存储属性，Modes.swift 有 29 处直接赋值）

    var isInIDEProjectMode: Bool = false
    var isInFolderOpenMode: Bool = false
    var isInWebLinkQueryMode: Bool = false
    var isInUtilityMode: Bool = false
    var isInBookmarkMode: Bool = false
    var isIn2FAMode: Bool = false
    var isInClaudeCodeMode: Bool = false
    var isInCodexMode: Bool = false

    // IDE 项目模式状态
    var currentIDEApp: SearchResult? = nil
    var currentIDEType: IDEType? = nil
    var ideProjects: [IDEProject] = []
    var filteredIDEProjects: [IDEProject] = []

    // 文件夹打开方式选择模式状态
    var currentFolder: SearchResult? = nil
    var folderOpeners: [IDERecentProjectsService.FolderOpenerApp] = []

    // 网页直达 Query 模式状态
    var currentWebLinkResult: SearchResult? = nil

    // 实用工具模式状态
    var currentUtilityIdentifier: String? = nil
    var currentUtilityResult: SearchResult? = nil

    // 书签搜索模式状态
    var bookmarkResults: [BookmarkItem] = []

    // 2FA 短信模式状态
    var twoFAResults: [TwoFactorCodeItem] = []

    // Claude Code / Codex 模式无特殊数据（布尔标志已由状态机涵盖）

    // IP 查询结果
    var ipQueryResults: [(label: String, ip: String)] = []
    var reminderResults: [SearchResult] = []

    // Kill 进程模式数据
    var killModeApps: [RunningProcessInfo] = []  // 已打开应用
    var killModePorts: [RunningProcessInfo] = []  // 监听端口进程
    var killModeAllItems: [RunningProcessInfo] = []  // 合并列表（用于显示）
    var killModeFilteredItems: [RunningProcessInfo] = []  // 搜索过滤后的列表

    // UUID 生成器状态
    var uuidUseHyphen: Bool = true  // 是否使用连字符
    var uuidUppercase: Bool = true  // 是否大写
    var uuidCount: Int = 1  // 生成数量
    var generatedUUIDs: [String] = []  // 生成的 UUID 列表
    var searchDebounceWorkItem: DispatchWorkItem?  // 搜索防抖（合并快速连续输入）
    var searchGeneration: UInt = 0  // 异步搜索代际，用于丢弃过期结果

    var uuidDebounceWorkItem: DispatchWorkItem?  // UUID 生成防抖

    // UUID 生成器 UI 组件
    let uuidOptionsView = NSView()  // 选项容器
    let hyphenCheckbox = NSButton(checkboxWithTitle: "连字符", target: nil, action: nil)
    let uppercaseRadio = NSButton(radioButtonWithTitle: "大写字符", target: nil, action: nil)
    let lowercaseRadio = NSButton(radioButtonWithTitle: "小写字符", target: nil, action: nil)
    let resultLabel = NSTextField(labelWithString: "结果")
    let uuidResultView = NSScrollView()  // UUID 结果滚动视图
    let uuidResultTextView = NSTextView()  // UUID 结果文本

    // URL 编码解码 UI 组件
    let urlCoderView = NSView()  // URL 编码解码容器
    let decodedURLLabel = NSTextField(labelWithString: "解码的 URL")
    let decodedURLScrollView = NSScrollView()  // 解码 URL 滚动视图
    let decodedURLTextView = NSTextView()  // 解码 URL 文本视图
    let decodedURLCopyButton = NSButton()
    let encodedURLLabel = NSTextField(labelWithString: "编码的 URL")
    let encodedURLScrollView = NSScrollView()  // 编码 URL 滚动视图
    let encodedURLTextView = NSTextView()  // 编码 URL 文本视图
    let encodedURLCopyButton = NSButton()
    var urlCoderDebounceWorkItem: DispatchWorkItem?  // URL 编码解码防抖

    // Base64 编码解码 UI 组件
    let base64CoderView = NSView()  // Base64 编码解码容器
    let originalTextLabel = NSTextField(labelWithString: "原始文本")
    let originalTextScrollView = NSScrollView()  // 原始文本滚动视图
    let originalTextView = NSTextView()  // 原始文本视图
    let originalTextCopyButton = NSButton()
    let base64TextLabel = NSTextField(labelWithString: "Base64")
    let base64TextScrollView = NSScrollView()  // Base64 文本滚动视图
    let base64TextView = NSTextView()  // Base64 文本视图
    let base64TextCopyButton = NSButton()
    var base64CoderDebounceWorkItem: DispatchWorkItem?  // Base64 编码解码防抖

    // 计算器状态
    var calculatorResult: String? = nil
    let calculatorResultLabel = NSTextField(labelWithString: "")

    // 汇率预览状态(与计算器共用同一 ghost 标签,语法互斥不会同时出现)
    var currencyConversion: CurrencyPreviewConversion? = nil  // 回车复制 / "=" 回填所需文案
    var currencyPreviewQuery: String? = nil  // 发起换算时的 query,用于丢弃过期网络回调
    var currencyManualTargetCode: String? = nil  // 用户点选胶囊后临时生效的目标币种(显式目标优先于它)
    let currencyTagView = CurrencyTagFlowView()  // 币种胶囊选择行(汇率命中时替换结果列表展示)

    /// 是否处于币种胶囊选择态(汇率预览激活,下方展示胶囊而非结果列表)
    var isCurrencyTagModeActive: Bool { !currencyTagView.isHidden }

    /// 统一清理计算器预览状态
    func clearCalculatorResult() {
        calculatorResult = nil
        calculatorResultLabel.isHidden = true
        calculatorResultLabel.stringValue = ""
        calculatorResultLabel.attributedStringValue = NSAttributedString(string: "")
    }

    /// 清理汇率预览状态(含胶囊行隐藏;ghost 标签由当前展示方统一渲染)
    func clearCurrencyPreview() {
        currencyConversion = nil
        currencyPreviewQuery = nil
        currencyManualTargetCode = nil
        currencyTagView.isHidden = true
    }

    /// 统一清理输入框内联预览(计算器 + 汇率),模式切换/面板隐藏时调用
    func clearInlinePreview() {
        clearCalculatorResult()
        clearCurrencyPreview()
    }

    var isInQuickActionsMode: Bool = false
    var quickActionsView: QuickActionsView?
    var reminderActionView: ReminderActionView?
    var currentQuickActionTarget: SearchResult?  // 当前操作的目标文件/文件夹

    // 缓存的默认搜索网页直达列表
    var cachedDefaultSearchWebLinks: [SearchResult]?

    // 键盘监听器
    var keyboardMonitor: Any?

    // MARK: - Constants
    let rowHeight: CGFloat = 44
    let headerHeight: CGFloat = 80

    // Placeholder 样式
    func setPlaceholder(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 22, weight: .regular),
        ]
        searchField.placeholderAttributedString = NSAttributedString(
            string: text, attributes: attributes)
    }

    // 用于 IDE 模式切换的约束
    var searchFieldLeadingToIcon: NSLayoutConstraint?
    var searchFieldLeadingToTag: NSLayoutConstraint?

    // MARK: - Lifecycle

    override func loadView() {
        let containerView = NSView()
        containerView.wantsLayer = true
        self.view = containerView

        // 1. 阴影层 - 用于显示外部阴影
        let shadowLayer = CALayer()
        shadowLayer.backgroundColor = NSColor.clear.cgColor
        shadowLayer.cornerRadius = 28
        shadowLayer.cornerCurve = .continuous
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowOffset = CGSize(width: 0, height: -12)
        shadowLayer.shadowRadius = 32
        containerView.layer?.addSublayer(shadowLayer)
        containerView.layer?.setValue(shadowLayer, forKey: "shadowLayer")

        // 2. 创建内容承载视图 (contentView)
        // 所有的搜索框、列表等都放在这个层，背景切换时不影响内容
        let contentWrapper = NSView()
        contentWrapper.wantsLayer = true
        contentWrapper.layer?.cornerRadius = 28
        contentWrapper.layer?.cornerCurve = .continuous
        contentWrapper.layer?.masksToBounds = true
        contentWrapper.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(contentWrapper)
        self.contentView = contentWrapper

        // 3. 预创建两种效果视图，根据设置切换可见性
        setupEffectViews(in: containerView)

        NSLayoutConstraint.activate([
            contentWrapper.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            contentWrapper.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            contentWrapper.topAnchor.constraint(equalTo: containerView.topAnchor),
            contentWrapper.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // 初始同步状态
        handleLiquidGlassSettingDidChange()
    }

    func setupEffectViews(in container: NSView) {
        // 创建传统毛玻璃层
        let vev = NSVisualEffectView()
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        vev.wantsLayer = true
        vev.layer?.cornerRadius = 28
        vev.layer?.cornerCurve = .continuous
        vev.layer?.masksToBounds = true
        vev.layer?.borderWidth = 0
        vev.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(vev, positioned: .below, relativeTo: contentView)
        self.visualEffectView = vev

        // 在 macOS 26+ 上预创建液态玻璃层
        if #available(macOS 26.0, *) {
            let gev = NSGlassEffectView()
            gev.style = .clear
            gev.tintColor = NSColor(named: "PanelBackgroundColor")
            gev.wantsLayer = true
            gev.layer?.cornerRadius = 28
            gev.layer?.cornerCurve = .continuous
            gev.layer?.masksToBounds = true
            gev.layer?.borderWidth = 0
            gev.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(gev, positioned: .below, relativeTo: contentView)
            self.glassEffectView = gev

            NSLayoutConstraint.activate([
                gev.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                gev.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                gev.topAnchor.constraint(equalTo: container.topAnchor),
                gev.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            vev.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vev.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vev.topAnchor.constraint(equalTo: container.topAnchor),
            vev.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("SearchPanelViewController: viewDidLoad called")
        setupUI()
        setupGlobalShortcutHint()
        setupKeyboardMonitor()
        setupNotificationObservers()

        // SearchEngine handles indexing automatically on init
        // Just trigger a reference to ensure it starts
        _ = searchEngine.isReady

        // 加载最近使用的应用
        loadRecentApps()

        // 如果提醒事项功能已启用且已授权，则加载提醒事项
        if RemindersSettings.load().isEnabled && RemindersService.shared.checkAuthorization() {
            loadReminders()
        }

        // Register for panel show callback to refresh recent apps
        PanelManager.shared.onWillShow = { [weak self] in
            guard let self = self else { return }

            // 如果已经在扩展模式（例如通过快捷键直接进入），不加载最近项目和提醒，避免覆盖扩展界面
            if self.isInAnyExtensionMode {
                self.updateVisibility()
                return
            }

            // 异步加载数据，加载完成后会自动触发刷新
            self.loadRecentApps()
            if RemindersSettings.load().isEnabled && RemindersService.shared.checkAuthorization() {
                self.loadReminders()
            }
            // 初始同步显示已有缓存数据
            self.performSearch("")
        }

        // Register for panel hide callback
        PanelManager.shared.onWillHide = { [weak self] in
            self?.resetState()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 更新阴影层的 frame 以匹配视图大小
        if let shadowLayer = view.layer?.value(forKey: "shadowLayer") as? CALayer {
            shadowLayer.frame = view.bounds
        }
    }

    // 支持顶部拖拽（简单的支持了一下，这不是重点）
    override func viewDidAppear() {
        super.viewDidAppear()
        self.view.window?.isMovableByWindowBackground = true
    }

    /// 设置通知观察者
    func loadReminders() {
        RemindersService.shared.fetchIncompleteReminders { [weak self] items in
            self?.reminderResults = items.map { SearchResult.fromReminder($0) }
            // 如果当前没有搜索内容且不在扩展模式，刷新显示
            if self?.searchField.stringValue.isEmpty == true && self?.isInAnyExtensionMode != true {
                self?.performSearch("")
            }
        }
    }

    func setupNotificationObservers() {
        // 监听直接进入 IDE 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterIDEModeDirectly(_:)),
            name: .enterIDEModeDirectly,
            object: nil
        )

        // 监听直接进入网页直达 Query 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterWebLinkQueryModeDirectly(_:)),
            name: .enterWebLinkQueryModeDirectly,
            object: nil
        )

        // 监听直接进入实用工具模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterUtilityModeDirectly(_:)),
            name: .enterUtilityModeDirectly,
            object: nil
        )

        // 监听直接进入书签模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterBookmarkModeDirectly),
            name: .enterBookmarkModeDirectly,
            object: nil
        )

        // 监听直接进入 2FA 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnter2FAModeDirectly),
            name: .enter2FAModeDirectly,
            object: nil
        )

        // 监听直接进入 Claude Code 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterClaudeCodeModeDirectly),
            name: .enterClaudeCodeModeDirectly,
            object: nil
        )

        // 监听直接进入 Codex 模式的通知（由快捷键触发）
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnterCodexModeDirectly),
            name: .enterCodexModeDirectly,
            object: nil
        )

        // 监听提醒事项变更
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemindersDidChange),
            name: Notification.Name("RemindersDataDidChange"),
            object: nil
        )

        // 监听清空提醒事项通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClearReminders),
            name: Notification.Name("ClearRemindersNotification"),
            object: nil
        )

        // 监听工具配置变更
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToolsConfigDidChange),
            name: .toolsConfigDidChange,
            object: nil
        )

        // 监听毛玻璃设置变更
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiquidGlassSettingDidChange),
            name: NSNotification.Name("enableLiquidGlassDidChange"),
            object: nil
        )
    }

    @objc func handleRemindersDidChange() {
        loadReminders()
    }

    @objc func handleClearReminders() {
        reminderResults = []
        // 如果当前没有搜索内容且不在扩展模式，刷新显示
        if searchField.stringValue.isEmpty && !isInAnyExtensionMode {
            performSearch("")
        }
    }

    /// 处理液态玻璃设置变化
    @objc func handleLiquidGlassSettingDidChange() {
        let useLiquidGlass =
            UserDefaults.standard.object(forKey: "enableLiquidGlass") as? Bool ?? true

        if #available(macOS 26.0, *) {
            // macOS 26+：切换 GlassView 和 VisualEffectView 的显示
            glassEffectView?.isHidden = !useLiquidGlass
            visualEffectView?.isHidden = useLiquidGlass

            // 如果切回到传统模式，确保材质正确
            if !useLiquidGlass {
                visualEffectView?.material = .hudWindow
            }
        } else {
            // 旧版本系统：仅使用 VisualEffectView，通过切换材质模拟
            glassEffectView?.isHidden = true
            visualEffectView?.isHidden = false
            visualEffectView?.material = .hudWindow
        }
    }

    /// 处理工具配置变化
    @objc func handleToolsConfigDidChange() {
        refreshDefaultSearchWebLinksCache()
    }

    /// 处理直接进入 IDE 模式的通知
    // MARK: - 表情包搜索模式

    // MARK: - Public Methods

    func focus() {
        // 每次显示面板时刷新状态，确保设置更改立即生效
        refreshDisplayMode()

        // 强制立即更新窗口高度，确保在 Simple 模式下启动时不会显示多余高度
        updateVisibility()

        // 确保搜索框在 UI 更新后获得焦点
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.view.window?.makeFirstResponder(self.searchField)
        }
    }

    /// 刷新显示模式（Simple/Full）
    func refreshDisplayMode() {
        // ⚠️ 重要：添加新的扩展模式时，必须在此处添加检查，否则会覆盖扩展模式的结果
        // 如果在扩展模式中，不要覆盖当前显示的结果
        if isInAnyExtensionMode {
            updateVisibility()
            return
        }

        if searchField.stringValue.isEmpty {
            performSearch("")
        }

        updateVisibility()
    }

    func resetState() {
        // 清理内联预览(计算器 + 汇率)
        clearInlinePreview()

        // 隐藏快捷操作面板
        hideQuickActions()

        // 状态机驱动清理：根据当前模式清理关联数据并恢复 UI
        switch currentMode {
        case .ideProject:
            currentIDEApp = nil
            currentIDEType = nil
            ideProjects = []
            filteredIDEProjects = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .folderOpen:
            currentFolder = nil
            folderOpeners = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .webLinkQuery:
            currentWebLinkResult = nil
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .utility:
            currentUtilityIdentifier = nil
            currentUtilityResult = nil
            ipQueryResults = []
            generatedUUIDs = []
            uuidOptionsView.isHidden = true
            urlCoderView.isHidden = true
            decodedURLTextView.string = ""
            encodedURLTextView.string = ""
            base64CoderView.isHidden = true
            originalTextView.string = ""
            base64TextView.string = ""
            restoreNormalModeUI()
            searchField.isHidden = false
            setPlaceholder("搜索应用或文档...")

        case .bookmark:
            bookmarkResults = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .twoFactorAuth:
            twoFAResults = []
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .claudeCode:
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .codex:
            restoreNormalModeUI()
            setPlaceholder("搜索应用或文档...")

        case .search:
            // 普通模式无需特殊清理
            break
        }

        // 退出扩展模式（清除所有布尔标志）
        isInIDEProjectMode = false
        isInFolderOpenMode = false
        isInWebLinkQueryMode = false
        isInUtilityMode = false
        isInBookmarkMode = false
        isIn2FAMode = false
        isInClaudeCodeMode = false
        isInCodexMode = false

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


    deinit {
        // 移除键盘监听器
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // 移除所有通知观察者
        NotificationCenter.default.removeObserver(self)
    }
}
