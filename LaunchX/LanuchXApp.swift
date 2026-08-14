import Combine
import SwiftUI

// 用于触发打开设置的辅助视图
struct SettingsOpenerView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsNotification)) { _ in
                openSettings()
            }
    }
}

// 自定义通知
extension Notification.Name {
    static let openSettingsNotification = Notification.Name("openSettingsNotification")
}

@main
struct LaunchXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 Settings scene 作为设置窗口
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var onboardingWindow: NSWindow?
    var settingsOpenerWindow: NSWindow?
    var isQuitting = false
    private var permissionObserver: AnyCancellable?
    private var hotKeyObservers: Set<AnyCancellable> = []
    private var isStatusItemSetup = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 关键路径：必须先检查 Translocation 和设置激活策略
        checkTranslocation()

        // Disable automatic window tabbing (Sierra+)
        NSWindow.allowsAutomaticWindowTabbing = false

        // 注册系统休眠通知（磁盘写入优化：确保休眠前保存数据）
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        // 2. Initialize the Search Panel (pure AppKit, no SwiftUI)
        PanelManager.shared.setup()

        // 拦截系统默认的 Cmd+Q 行为
        if let mainMenu = NSApp.mainMenu {
            for item in mainMenu.items {
                if let submenu = item.submenu {
                    for subItem in submenu.items {
                        if subItem.action == #selector(NSApplication.terminate(_:)) {
                            subItem.target = self
                            subItem.action = #selector(handleQuitMenuClick)
                        }
                    }
                }
            }
        }

        // 3. Check permissions first before setting up hotkey
        checkPermissionsAndSetup()

        // 4. 延迟执行非关键路径操作，加速启动
        DispatchQueue.main.async { [weak self] in
            self?.setupSettingsOpenerWindow()
            self?.observeHotKeyChanges()
            self?.migrateRemindersSettings()
            self?.applyKeyRemapSettings()
            // 启动主线程看门狗：检测主线程被系统输入法切换遥测(Caps Lock)长时间卡死时，
            // 自动暂停键盘事件拦截以尝试恢复响应。
            MainThreadWatchdog.shared.start()
        }
    }

    @objc private func systemWillSleep() {
        print("LaunchX: System will sleep, saving data immediately")
        // 立即保存剪贴板数据
        ClipboardService.shared.saveImmediately()
    }

    /// 应用保存的键盘映射设置
    private func applyKeyRemapSettings() {
        // 所有键盘映射功能都需要辅助功能权限并通过 CGEventTap 实现
        guard AXIsProcessTrusted() else { return }

        let hyperKey = UserDefaults.standard.bool(forKey: "keyRemapHyperKey")
        let quoteSwap = UserDefaults.standard.bool(forKey: "keyRemapQuoteSwap")

        KeyRemapService.shared.applySettings(hyper: hyperKey, quote: quoteSwap)
    }

    /// 检查是否运行在 App Translocation 模式下
    /// 如果没有苹果开发者账号签名，直接从下载文件夹运行会导致该模式，从而破坏自动更新逻辑
    private func checkTranslocation() {
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") {
            print("LaunchX: Detected App Translocation: \(bundlePath)")
            let alert = NSAlert()
            alert.messageText = "建议移动到应用程序文件夹"
            alert.informativeText =
                "检测到应用当前运行在系统随机路径（App Translocation）。这通常是因为应用未签名且直接在下载目录运行导致的。这会导致：\n\n1. 自动更新后权限（如辅助功能）会丢失\n2. 更新完成后可能无法自动重新打开应用\n\n请将 LaunchX 移动到“应用程序”(/Applications) 文件夹后重新打开。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "我知道了")
            alert.runModal()
        }
    }

    /// 迁移提醒事项设置：为已授权用户自动启用功能
    private func migrateRemindersSettings() {
        // 检查是否已经迁移过（通过检查 UserDefaults 中是否存在设置）
        let hasMigrated = UserDefaults.standard.object(forKey: "remindersEnabled") != nil

        if !hasMigrated {
            // 检查用户是否已经授权提醒事项
            if RemindersService.shared.checkAuthorization() {
                // 已授权用户，自动启用功能
                var settings = RemindersSettings.load()
                settings.isEnabled = true
                settings.save()
            }
        }
    }

    /// 创建隐藏窗口来承载 SettingsOpenerView
    private func setupSettingsOpenerWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: SettingsOpenerView())
        window.isReleasedWhenClosed = false
        window.orderOut(nil)  // 确保窗口不显示
        settingsOpenerWindow = window
    }

    /// 监听快捷键变化，更新菜单显示
    private func observeHotKeyChanges() {
        let hotKeyService = HotKeyService.shared

        // 监听 keyCode 变化
        hotKeyService.$currentKeyCode
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusItemMenu()
            }
            .store(in: &hotKeyObservers)

        // 监听 modifiers 变化
        hotKeyService.$currentModifiers
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusItemMenu()
            }
            .store(in: &hotKeyObservers)

        // 监听双击模式变化
        hotKeyService.$useDoubleTapModifier
            .dropFirst()
            .sink { [weak self] _ in
                self?.updateStatusItemMenu()
            }
            .store(in: &hotKeyObservers)
    }

    /// 更新状态栏菜单的快捷键显示
    private func updateStatusItemMenu() {
        guard let menu = statusItem.menu,
            let openItem = menu.items.first(where: { $0.action == #selector(togglePanel) })
        else {
            return
        }

        let hotKeyService = HotKeyService.shared
        let keyCode = hotKeyService.currentKeyCode
        let modifiers = hotKeyService.currentModifiers
        let useDoubleTap = hotKeyService.useDoubleTapModifier

        if !useDoubleTap {
            let keyChar = DoubleTapModifier.keyCharacter(for: keyCode)
            openItem.keyEquivalent = keyChar
            openItem.keyEquivalentModifierMask = DoubleTapModifier.cocoaModifiers(from: modifiers)
        } else {
            // 双击模式不显示快捷键
            openItem.keyEquivalent = ""
            openItem.keyEquivalentModifierMask = []
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        print("LaunchX: applicationDidBecomeActive called")
        // 只有在辅助功能已授权且没有显示引导页时，才强制设为 accessory 模式
        if PermissionService.shared.isAccessibilityGranted && onboardingWindow == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if NSApp.activationPolicy() != .accessory {
                    print(
                        "LaunchX: Forcing accessory mode (current: \(NSApp.activationPolicy().rawValue))"
                    )
                    NSApp.setActivationPolicy(.accessory)
                    print(
                        "LaunchX: Accessory mode forced (new: \(NSApp.activationPolicy().rawValue))"
                    )
                }
            }
        }

        // 只有在权限未授予时才强制显示授权窗口
        // 避免在用户已授权后仍然弹出授权窗口
        if let window = onboardingWindow,
            !window.isKeyWindow,
            !PermissionService.shared.isAccessibilityGranted
        {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    func checkPermissionsAndSetup() {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        let didJustUpdate = UserDefaults.standard.bool(forKey: "didJustUpdateAndRelaunch")

        // 同步检查辅助功能权限（这是最重要的权限）
        let hasAccessibility = AXIsProcessTrusted()

        print(
            "LaunchX: isFirstLaunch=\(isFirstLaunch), hasAccessibility=\(hasAccessibility), didJustUpdate=\(didJustUpdate)"
        )

        // 异步更新其他权限状态（用于 UI 显示）
        PermissionService.shared.checkAllPermissions()

        // 如果是更新后重启，等待更长时间让系统重新验证签名和权限
        let delay: TimeInterval = didJustUpdate ? 2.0 : 0.5

        // 根据辅助功能权限状态设置初始运行模式
        // 如果没有权限，设为 regular 以便正确显示引导窗口；如果有权限，设为 accessory
        let initialPolicy: NSApplication.ActivationPolicy = hasAccessibility ? .accessory : .regular

        print(
            "LaunchX: Setting activation policy to \(initialPolicy == .accessory ? "accessory" : "regular") (current: \(NSApp.activationPolicy().rawValue))"
        )
        NSApp.setActivationPolicy(initialPolicy)
        print(
            "LaunchX: About to create status item immediately, resetting isStatusItemSetup from \(self.isStatusItemSetup)"
        )
        self.isStatusItemSetup = false
        self.setupStatusItem()
        print("LaunchX: Status item created immediately on app launch")

        // 清除更新标记
        if didJustUpdate {
            UserDefaults.standard.removeObject(forKey: "didJustUpdateAndRelaunch")
        }

        // 等待权限状态更新后检查是否所有权限都已授予
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            let accessibility = PermissionService.shared.isAccessibilityGranted
            let fullDisk = PermissionService.shared.isFullDiskAccessGranted

            print(
                "LaunchX: accessibility=\(accessibility), fullDisk=\(fullDisk)"
            )

            if isFirstLaunch {
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

                if accessibility {
                    // 首次启动且辅助功能已授予，直接进入应用
                    print("LaunchX: First launch and accessibility granted, showing panel")
                    self.setupHotKeyAndShowPanel()
                } else {
                    print("LaunchX: First launch, opening onboarding")
                    self.openOnboarding()
                }
            } else if !accessibility {
                print("LaunchX: Accessibility not granted, opening onboarding")
                // 确保没有权限时处于 regular 模式，以便显示引导窗口
                NSApp.setActivationPolicy(.regular)
                self.openOnboarding()
            } else {
                // 权限已授予，确保处于 accessory 模式
                NSApp.setActivationPolicy(.accessory)
                print("LaunchX: Accessibility granted, showing panel")
                self.setupHotKeyAndShowPanel()
            }

            // 监听权限变化，当辅助功能权限授予后设置热键
            self.observePermissionChanges()
        }
    }

    private func observePermissionChanges() {
        permissionObserver = PermissionService.shared.$isAccessibilityGranted
            .removeDuplicates()
            .sink { [weak self] isGranted in
                guard let self = self else { return }

                if isGranted {
                    // 权限被授予时立即设置 menubar 图标和热键
                    NSApp.setActivationPolicy(.accessory)
                    // 强制重置标志以确保 menubar 图标被创建
                    self.isStatusItemSetup = false
                    self.setupStatusItem()
                    self.setupHotKey()
                    // 异步应用键盘映射设置（含同步 Process 调用，避免阻塞主线程导致引导页不更新）
                    DispatchQueue.main.async {
                        self.applyKeyRemapSettings()
                    }
                    print("LaunchX: Accessibility granted, statusItem and hotkey setup complete")
                }
            }
    }

    private func setupHotKey() {
        // 只有辅助功能权限授予后才设置热键
        guard AXIsProcessTrusted() else { return }

        // Setup Global HotKey (Option + Space)
        HotKeyService.shared.setupGlobalHotKey()

        // Bind HotKey Action
        HotKeyService.shared.onHotKeyPressed = {
            PanelManager.shared.togglePanel()
        }

        // 设置自定义快捷键回调
        setupCustomHotKeys()

        print("LaunchX: HotKey setup complete")
    }

    /// 设置自定义快捷键
    private func setupCustomHotKeys() {
        // 设置自定义快捷键触发回调（使用 ToolExecutor）
        HotKeyService.shared.onCustomHotKeyPressed = { toolId, isExtension in
            ToolExecutor.shared.execute(toolId: toolId, isExtension: isExtension)
        }

        // 设置书签快捷键回调
        HotKeyService.shared.onBookmarkHotKeyPressed = {
            // 检查书签功能是否启用
            let settings = BookmarkSettings.load()
            guard settings.isEnabled else { return }
            PanelManager.shared.showPanelInBookmarkMode()
        }

        // 设置 2FA 快捷键回调
        HotKeyService.shared.on2FAHotKeyPressed = {
            // 检查 2FA 功能是否启用
            let settings = TwoFactorAuthSettings.load()
            guard settings.isEnabled else { return }
            PanelManager.shared.showPanelIn2FAMode()
        }

        // 设置剪贴板快捷键回调
        HotKeyService.shared.onClipboardHotKeyPressed = {
            // 检查剪贴板功能是否启用
            let settings = ClipboardSettings.load()
            guard settings.isEnabled else { return }
            ClipboardPanelManager.shared.togglePanel()
        }

        // 设置纯文本粘贴快捷键回调
        HotKeyService.shared.onPlainTextPasteHotKeyPressed = {
            // 获取当前剪贴板面板选中项，粘贴为纯文本
            ClipboardPanelManager.shared.pasteSelectedAsPlainText()
        }

        // 设置 Claude Code 快捷键回调
        HotKeyService.shared.onClaudeCodeHotKeyPressed = {
            let settings = ClaudeCodeSwitcherSettings.load()
            guard settings.isEnabled else { return }
            PanelManager.shared.showPanel()
            NotificationCenter.default.post(name: .init("enterClaudeCodeModeDirectly"), object: nil)
        }

        // 设置 Codex 快捷键回调
        HotKeyService.shared.onCodexHotKeyPressed = {
            let settings = CodexSwitcherSettings.load()
            guard settings.isEnabled else { return }
            PanelManager.shared.showPanel()
            NotificationCenter.default.post(name: .init("enterCodexModeDirectly"), object: nil)
        }

        // 设置股票面板快捷键回调
        HotKeyService.shared.onStockHotKeyPressed = {
            let settings = StockSettings.load()
            guard settings.isEnabled else { return }
            StockPanelManager.shared.togglePanel()
        }

        // 设置选词翻译快捷键回调
        HotKeyService.shared.onTranslateSelectionHotKeyPressed = {
            let settings = AITranslateSettings.load()
            guard settings.isEnabled else { return }
            AITranslatePanelManager.shared.showPanelWithSelection()
        }

        // 设置输入翻译快捷键回调
        HotKeyService.shared.onTranslateInputHotKeyPressed = {
            let settings = AITranslateSettings.load()
            guard settings.isEnabled else { return }
            AITranslatePanelManager.shared.togglePanel()
        }

        // 优先从新的 ToolsConfig 加载，否则回退到 CustomItemsConfig
        let toolsConfig = ToolsConfig.load()
        if !toolsConfig.tools.isEmpty {
            HotKeyService.shared.reloadToolHotKeys(from: toolsConfig)
            print("LaunchX: Tool hotkeys loaded from ToolsConfig")
        } else {
            let config = CustomItemsConfig.load()
            HotKeyService.shared.reloadCustomHotKeys(from: config)
            print("LaunchX: Custom hotkeys loaded from CustomItemsConfig")
        }

        // 加载书签快捷键
        HotKeyService.shared.loadBookmarkHotKey()

        // 加载 2FA 快捷键
        HotKeyService.shared.load2FAHotKey()

        // 加载剪贴板快捷键
        HotKeyService.shared.loadClipboardHotKey()
        HotKeyService.shared.loadPlainTextPasteHotKey()

        // 加载翻译快捷键
        HotKeyService.shared.loadTranslateHotKeys()

        // 加载 Claude Code 快捷键
        HotKeyService.shared.loadClaudeCodeHotKey()

        // 加载 Codex 快捷键
        HotKeyService.shared.loadCodexHotKey()

        // 加载股票面板快捷键
        HotKeyService.shared.loadStockHotKey()

        // 启动剪贴板监听
        ClipboardService.shared.startMonitoring()

        // 启动 Snippet 监听
        SnippetService.shared.startMonitoring()
    }

    private func setupHotKeyAndShowPanel() {
        setupHotKey()
        // 显示搜索面板
        PanelManager.shared.togglePanel()
    }

    func openOnboarding() {
        print("LaunchX: Opening onboarding window")

        if onboardingWindow == nil {
            let rootView = OnboardingView { [weak self] in
                guard let self = self else { return }
                print("LaunchX: Onboarding onFinish callback called")

                // 1. 设置热键并显示面板
                self.setupHotKeyAndShowPanel()

                // 2. 关闭引导页窗口并清理引用
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
                print("LaunchX: Onboarding window closed")
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
                styleMask: [.titled, .fullSizeContentView],  // 移除 .closable - 去掉关闭按钮
                backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: rootView)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.title = "欢迎使用 LaunchX"

            // Hide zoom and minimize buttons for a cleaner look
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true

            onboardingWindow = window
        }

        // 启动时已经是 regular 模式，直接显示窗口
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()  // 强制到最前面
        NSApp.activate(ignoringOtherApps: true)

        print("LaunchX: Onboarding window frame: \(onboardingWindow?.frame ?? .zero)")
        print("LaunchX: Onboarding window isVisible: \(onboardingWindow?.isVisible ?? false)")
    }

    func setupStatusItem() {
        print(
            "LaunchX: setupStatusItem called, isStatusItemSetup=\(isStatusItemSetup), statusItem!=nil=\(statusItem != nil)"
        )

        // Prevent multiple setups
        if isStatusItemSetup && statusItem != nil {
            print("LaunchX: StatusItem already setup, skipping")
            return
        }

        // Clean up existing status item if it exists
        if let existingItem = statusItem {
            NSStatusBar.system.removeStatusItem(existingItem)
            print("LaunchX: Removed existing status item")
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        print("LaunchX: statusItem created: \(statusItem != nil)")

        if let button = statusItem.button {
            // 尝试使用系统图标作为备选
            if let image = NSImage(named: NSImage.Name("StatusBarIcon")) {
                image.isTemplate = true
                button.image = image
                print("LaunchX: Using StatusBarIcon")
            } else {
                // 备选：使用系统图标
                button.image = NSImage(
                    systemSymbolName: "magnifyingglass", accessibilityDescription: "LaunchX")
                print("LaunchX: Using system icon as fallback")
            }
            print("LaunchX: button.image set: \(button.image != nil)")
        }

        // 创建并设置菜单
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 获取当前快捷键设置
        let hotKeyService = HotKeyService.shared
        let keyCode = hotKeyService.currentKeyCode
        let modifiers = hotKeyService.currentModifiers
        let useDoubleTap = hotKeyService.useDoubleTapModifier

        let openItem = NSMenuItem(
            title: "打开 LaunchX", action: #selector(togglePanel), keyEquivalent: "")
        openItem.target = self
        openItem.isEnabled = true

        // 设置快捷键显示
        if !useDoubleTap {
            // 传统快捷键模式：设置 keyEquivalent
            let keyChar = DoubleTapModifier.keyCharacter(for: keyCode)
            openItem.keyEquivalent = keyChar
            openItem.keyEquivalentModifierMask = DoubleTapModifier.cocoaModifiers(from: modifiers)
        }
        // 双击模式不显示快捷键（因为无法在菜单中表示）

        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.isEnabled = true
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "检查更新...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = true
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(explicitQuit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.isVisible = true
        print("LaunchX: StatusItem menu set, items count: \(menu.items.count)")

        print(
            "LaunchX: StatusItem setup complete, button: \(statusItem.button != nil), menu: \(statusItem.menu != nil)"
        )

        // Mark as properly setup
        isStatusItemSetup = true
    }

    @objc func togglePanel() {
        print("LaunchX: togglePanel called via menubar")
        PanelManager.shared.togglePanel()
    }

    @objc func handleQuitMenuClick() {
        print("LaunchX: Cmd+Q intercepted, hiding instead of quitting")
        PanelManager.shared.hidePanel()
    }

    @objc func openSettings() {
        PanelManager.shared.hidePanel()

        // 打开设置时恢复权限检查（用户可能需要调整权限）
        PermissionService.shared.startPeriodicCheck()

        // 激活应用，确保设置窗口在当前活跃的空间/屏幕打开
        NSApp.activate(ignoringOtherApps: true)

        // 发送通知，让 SettingsOpenerView 通过 @Environment(\.openSettings) 打开设置
        // 不需要切换到 regular 模式，避免 Dock 图标出现
        NotificationCenter.default.post(name: .openSettingsNotification, object: nil)
    }

    @objc func explicitQuit() {
        // Clean up keyboard remapping
        KeyRemapService.shared.stopEventTap()

        // Clean up status item before quitting
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        isStatusItemSetup = false
        isQuitting = true
        NSApp.terminate(nil)
    }

    @objc func checkForUpdates() {
        UpdateService.shared.checkForUpdates(manual: true)
    }

    // Intercept termination request (Cmd+Q) to keep the app running in the background
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let isUpdating = UpdateService.shared.isPreparingForUpdate
        print(
            "LaunchX: applicationShouldTerminate called, isQuitting: \(isQuitting), isUpdating: \(isUpdating)"
        )

        // 1. 明确点击"退出"菜单或正在通过 Sparkle 更新，允许退出
        if isQuitting || isUpdating {
            print("LaunchX: Explicit quit or Sparkle update, allowing termination")

            // 立即保存剪贴板数据（磁盘写入优化：确保不丢失数据）
            ClipboardService.shared.saveImmediately()

            // 确保停止权限检查定时器，防止干扰退出
            PermissionService.shared.stopPeriodicCheck()
            return .terminateNow
        }

        // 2. 检查退出原因
        let currentEvent = NSApp.currentEvent
        let isCommandQ =
            currentEvent?.type == .keyDown && currentEvent?.modifierFlags.contains(.command) == true
            && currentEvent?.charactersIgnoringModifiers == "q"

        // 如果是 Cmd+Q 触发的，且当前处于后台模式且已授权，则拦截并隐藏（符合菜单栏工具习惯）
        if isCommandQ && NSApp.activationPolicy() == .accessory
            && PermissionService.shared.isAccessibilityGranted
        {
            print("LaunchX: Intercepting Cmd+Q, hiding panel instead")
            DispatchQueue.main.async {
                PanelManager.shared.hidePanel()
                for window in NSApp.windows where window.isVisible {
                    window.close()
                }
                NSApp.hide(nil)
            }
            return .terminateCancel
        }

        // 3. 其他情况（如系统关机、用户在设置中授予权限后被要求重启）
        // 安排自动重新启动，因为 macOS 对 accessory 模式的菜单栏应用 relaunch 支持不可靠
        print("LaunchX: System initiated termination, scheduling relaunch...")

        // 立即保存剪贴板数据（磁盘写入优化：确保不丢失数据）
        ClipboardService.shared.saveImmediately()

        scheduleRelaunch()
        PermissionService.shared.stopPeriodicCheck()
        return .terminateNow
    }

    /// 安排应用在退出后自动重新启动
    /// 使用外部 shell 进程等待当前进程退出后再重新打开应用
    private func scheduleRelaunch() {
        let bundlePath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier

        // 使用 shell 脚本：等待当前进程退出后，延迟一小段时间再重新打开应用
        let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; sleep 0.5; open "\(bundlePath)"
            """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        do {
            try process.run()
            print("LaunchX: Relaunch process scheduled (pid: \(process.processIdentifier))")
        } catch {
            print("LaunchX: Failed to schedule relaunch: \(error)")
        }
    }
}
