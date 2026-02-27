import Carbon
import Cocoa
import Combine

// C-convention callback function for the event handler
private func globalHotKeyHandler(
    nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?
) -> OSStatus {
    return HotKeyService.shared.handleEvent(event)
}

/// 双击修饰键类型
enum DoubleTapModifier: String, Codable, CaseIterable {
    case command = "command"
    case option = "option"
    case control = "control"
    case shift = "shift"

    var displayName: String {
        switch self {
        case .command: return "⌘ Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .shift: return "⇧ Shift"
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }

    /// 将 keyCode 转换为 NSMenuItem 的 keyEquivalent 字符
    static func keyCharacter(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Delete: return "\u{8}"  // Backspace
        case kVK_Escape: return "\u{1B}"
        case kVK_ANSI_A: return "a"
        case kVK_ANSI_B: return "b"
        case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"
        case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"
        case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"
        case kVK_ANSI_J: return "j"
        case kVK_ANSI_K: return "k"
        case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"
        case kVK_ANSI_O: return "o"
        case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"
        case kVK_ANSI_R: return "r"
        case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"
        case kVK_ANSI_V: return "v"
        case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"
        case kVK_ANSI_Z: return "z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return ""
        }
    }

    /// 将 Carbon 修饰键转换为 Cocoa NSEvent.ModifierFlags
    static func cocoaModifiers(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
}

class HotKeyService: ObservableObject {
    static let shared = HotKeyService()

    // MARK: - 主快捷键（打开搜索面板）

    /// 主快捷键触发回调
    var onHotKeyPressed: (() -> Void)?

    private var mainHotKeyRef: EventHotKeyRef?
    private let mainHotKeyId: UInt32 = 1

    /// 主快捷键的按键代码
    @Published var currentKeyCode: UInt32 = UInt32(kVK_Space)
    /// 主快捷键的修饰键
    @Published var currentModifiers: UInt32 = UInt32(optionKey)
    @Published var isEnabled: Bool = true

    // MARK: - 双击修饰键支持

    /// 是否使用双击修饰键模式
    @Published var useDoubleTapModifier: Bool = false
    /// 当前设置的双击修饰键
    @Published var doubleTapModifier: DoubleTapModifier = .command

    /// 双击检测相关
    private var lastModifierPressTime: Date?
    private var lastPressedModifier: DoubleTapModifier?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private let doubleTapInterval: TimeInterval = 0.3  // 双击间隔阈值
    private var previousFlags: NSEvent.ModifierFlags = []

    // MARK: - 自定义快捷键

    /// 自定义快捷键触发回调 (itemId, isExtension)
    var onCustomHotKeyPressed: ((UUID, Bool) -> Void)?

    /// 自定义快捷键引用: hotKeyId -> EventHotKeyRef
    private var customHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// 自定义快捷键动作: hotKeyId -> (itemId, isExtension)
    private var customHotKeyActions: [UInt32: (UUID, Bool)] = [:]
    /// 快捷键配置缓存: hotKeyId -> HotKeyConfig（用于冲突检测）
    private var customHotKeyConfigs: [UInt32: HotKeyConfig] = [:]
    /// 下一个可用的快捷键 ID（从 100 开始，避免与主快捷键冲突）
    private var nextCustomHotKeyId: UInt32 = 100

    // MARK: - 书签扩展快捷键

    /// 书签快捷键触发回调
    var onBookmarkHotKeyPressed: (() -> Void)?
    /// 书签快捷键引用
    private var bookmarkHotKeyRef: EventHotKeyRef?
    /// 书签快捷键 ID
    private let bookmarkHotKeyId: UInt32 = 2

    /// 2FA 快捷键触发回调
    var on2FAHotKeyPressed: (() -> Void)?
    /// 2FA 快捷键引用
    private var twoFAHotKeyRef: EventHotKeyRef?
    /// 2FA 快捷键 ID
    private let twoFAHotKeyId: UInt32 = 3

    // MARK: - 剪贴板扩展快捷键

    /// 剪贴板快捷键触发回调
    var onClipboardHotKeyPressed: (() -> Void)?
    /// 纯文本粘贴快捷键触发回调
    var onPlainTextPasteHotKeyPressed: (() -> Void)?
    /// 剪贴板快捷键引用
    private var clipboardHotKeyRef: EventHotKeyRef?
    /// 纯文本粘贴快捷键引用
    private var plainTextPasteHotKeyRef: EventHotKeyRef?
    /// 剪贴板快捷键 ID
    private let clipboardHotKeyId: UInt32 = 4
    /// 纯文本粘贴快捷键 ID
    private let plainTextPasteHotKeyId: UInt32 = 5

    // MARK: - AI 翻译快捷键

    /// 选词翻译快捷键触发回调
    var onTranslateSelectionHotKeyPressed: (() -> Void)?
    /// 输入翻译快捷键触发回调
    var onTranslateInputHotKeyPressed: (() -> Void)?
    /// 选词翻译快捷键引用
    private var translateSelectionHotKeyRef: EventHotKeyRef?
    /// 输入翻译快捷键引用
    private var translateInputHotKeyRef: EventHotKeyRef?
    /// 选词翻译快捷键 ID
    private let translateSelectionHotKeyId: UInt32 = 6
    /// 输入翻译快捷键 ID
    private let translateInputHotKeyId: UInt32 = 7

    // MARK: - 表情包快捷键

    /// 表情包快捷键触发回调
    var onMemeHotKeyPressed: (() -> Void)?
    /// 表情包快捷键引用
    private var memeHotKeyRef: EventHotKeyRef?
    /// 表情包快捷键 ID
    private let memeHotKeyId: UInt32 = 8

    // MARK: - 表情包收藏快捷键

    /// 表情包收藏快捷键触发回调
    var onFavoriteHotKeyPressed: (() -> Void)?
    /// 表情包收藏快捷键引用
    private var favoriteHotKeyRef: EventHotKeyRef?
    /// 表情包收藏快捷键 ID
    private let favoriteHotKeyId: UInt32 = 9

    // MARK: - 私有属性

    private let hotKeySignature: OSType
    private var eventHandlerRef: EventHandlerRef?

    /// 是否处于录制模式（暂停状态）
    private(set) var isSuspended: Bool = false

    // MARK: - 初始化

    private init() {
        // Create signature "LnHX"
        let c1 = UInt32(byteAt("L", 0))
        let c2 = UInt32(byteAt("n", 0))
        let c3 = UInt32(byteAt("H", 0))
        let c4 = UInt32(byteAt("X", 0))

        self.hotKeySignature = OSType((c1 << 24) | (c2 << 16) | (c3 << 8) | c4)

        // 监听配置导入通知
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigImport),
            name: NSNotification.Name("AppConfigDidImport"), object: nil)
    }

    @objc private func handleConfigImport() {
        print("HotKeyService: Config imported, reloading all hotkeys")
        DispatchQueue.main.async {
            // 1. 重新加载主快捷键
            self.loadHotKeySettings()

            // 2. 重新加载自定义项目快捷键
            let customConfig = CustomItemsConfig.load()
            self.reloadCustomHotKeys(from: customConfig)

            // 3. 重新加载工具快捷键
            let toolsConfig = ToolsConfig.load()
            self.reloadToolHotKeys(from: toolsConfig)

            // 4. 重新加载其他特定功能快捷键
            self.loadBookmarkHotKey()
            self.load2FAHotKey()
            self.loadClipboardHotKey()
            self.loadPlainTextPasteHotKey()
            self.loadTranslateHotKeys()
            self.loadMemeHotKey()
        }
    }

    // MARK: - 主快捷键方法

    func setupGlobalHotKey() {
        // Install event handler only once
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            print("HotKeyService: Failed to install event handler. Status: \(status)")
            return
        }

        // Load saved configuration
        loadHotKeySettings()
    }

    /// 加载保存的快捷键设置
    private func loadHotKeySettings() {
        // 检查是否使用双击修饰键模式
        let savedUseDoubleTap = UserDefaults.standard.bool(forKey: "hotKeyUseDoubleTap")

        if savedUseDoubleTap {
            // 加载双击修饰键设置
            if let savedModifier = UserDefaults.standard.string(forKey: "hotKeyDoubleTapModifier"),
                let modifier = DoubleTapModifier(rawValue: savedModifier)
            {
                enableDoubleTapModifier(modifier)
            } else {
                enableDoubleTapModifier(.command)
            }
        } else {
            // 加载传统快捷键设置
            let savedKeyCode = UserDefaults.standard.object(forKey: "hotKeyKeyCode") as? Int
            let savedModifiers = UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int

            if let key = savedKeyCode, let mods = savedModifiers {
                registerMainHotKey(keyCode: UInt32(key), modifiers: UInt32(mods))
            } else {
                registerMainHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
            }
        }
    }

    /// 注册主快捷键（打开搜索面板）
    func registerMainHotKey(keyCode: UInt32, modifiers: UInt32) {
        // 先禁用双击修饰键模式
        disableDoubleTapModifier()

        // Unregister existing if any
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
        }

        self.currentKeyCode = keyCode
        self.currentModifiers = modifiers
        self.useDoubleTapModifier = false

        // Save persistence
        UserDefaults.standard.set(Int(keyCode), forKey: "hotKeyKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotKeyModifiers")
        UserDefaults.standard.set(false, forKey: "hotKeyUseDoubleTap")

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: mainHotKeyId)

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &mainHotKeyRef
        )

        if registerStatus != noErr {
            print("HotKeyService: Failed to register main hotkey. Status: \(registerStatus)")
        } else {
            print("HotKeyService: Registered Main HotKey (Code: \(keyCode), Mods: \(modifiers))")
        }
    }

    /// 兼容旧的方法名
    func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        registerMainHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// 清除主快捷键
    func clearHotKey() {
        // 清除传统快捷键
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
        }

        // 清除双击修饰键监听
        disableDoubleTapModifier()

        currentKeyCode = 0
        currentModifiers = 0
        useDoubleTapModifier = false

        UserDefaults.standard.removeObject(forKey: "hotKeyKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotKeyModifiers")
        UserDefaults.standard.removeObject(forKey: "hotKeyUseDoubleTap")
        UserDefaults.standard.removeObject(forKey: "hotKeyDoubleTapModifier")
        print("HotKeyService: Cleared Main HotKey")
    }

    // MARK: - 双击修饰键方法

    /// 启用双击修饰键模式
    func enableDoubleTapModifier(_ modifier: DoubleTapModifier) {
        // 先清除传统快捷键
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
        }

        self.useDoubleTapModifier = true
        self.doubleTapModifier = modifier
        self.currentKeyCode = 0
        self.currentModifiers = 0

        // 保存设置
        UserDefaults.standard.set(true, forKey: "hotKeyUseDoubleTap")
        UserDefaults.standard.set(modifier.rawValue, forKey: "hotKeyDoubleTapModifier")

        // 启动监听
        startDoubleTapMonitoring()

        print("HotKeyService: Enabled Double-Tap \(modifier.displayName) mode")
    }

    /// 禁用双击修饰键模式
    private func disableDoubleTapModifier() {
        stopDoubleTapMonitoring()
        lastModifierPressTime = nil
        lastPressedModifier = nil
        previousFlags = []
    }

    /// 开始监听双击修饰键
    private func startDoubleTapMonitoring() {
        stopDoubleTapMonitoring()

        // 全局监听（其他应用激活时）
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // 本地监听（本应用激活时）
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    /// 停止监听双击修饰键
    private func stopDoubleTapMonitoring() {
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
    }

    /// 处理修饰键变化事件
    private func handleFlagsChanged(_ event: NSEvent) {
        let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let targetFlag = doubleTapModifier.flag

        // 检测目标修饰键是否刚被按下（从无到有）
        let wasPressed = !previousFlags.contains(targetFlag) && currentFlags.contains(targetFlag)
        // 检测目标修饰键是否刚被释放（从有到无）
        let wasReleased = previousFlags.contains(targetFlag) && !currentFlags.contains(targetFlag)

        // 确保只有目标修饰键被按下，没有其他修饰键
        let onlyTargetPressed =
            currentFlags.subtracting([.capsLock, .numericPad, .function]) == targetFlag

        if wasPressed && onlyTargetPressed {
            let now = Date()

            if let lastTime = lastModifierPressTime,
                let lastModifier = lastPressedModifier,
                lastModifier == doubleTapModifier,
                now.timeIntervalSince(lastTime) < doubleTapInterval
            {
                // 双击检测成功
                lastModifierPressTime = nil
                lastPressedModifier = nil

                DispatchQueue.main.async { [weak self] in
                    self?.onHotKeyPressed?()
                }
            } else {
                // 记录第一次按下
                lastModifierPressTime = now
                lastPressedModifier = doubleTapModifier
            }
        } else if wasReleased {
            // 释放时不做特殊处理，保留上次按下时间用于双击检测
        } else if !currentFlags.intersection([.command, .option, .control, .shift]).isEmpty
            && currentFlags.intersection([.command, .option, .control, .shift]) != targetFlag
        {
            // 如果按下了其他修饰键，重置状态
            lastModifierPressTime = nil
            lastPressedModifier = nil
        }

        previousFlags = currentFlags
    }

    /// 获取当前快捷键的显示字符串
    var currentHotKeyDisplayString: String {
        if useDoubleTapModifier {
            return "\(doubleTapModifier.symbol) \(doubleTapModifier.symbol)"
        } else if currentKeyCode != 0 {
            return HotKeyService.displayString(for: currentModifiers, keyCode: currentKeyCode)
        } else {
            return ""
        }
    }

    // MARK: - 自定义快捷键方法

    /// 注册自定义快捷键
    /// - Parameters:
    ///   - keyCode: 按键代码
    ///   - modifiers: 修饰键
    ///   - itemId: 关联的项目 ID
    ///   - isExtension: 是否为"进入扩展"快捷键
    /// - Returns: 快捷键 ID，失败返回 nil
    @discardableResult
    func registerCustomHotKey(
        keyCode: UInt32, modifiers: UInt32, itemId: UUID, isExtension: Bool
    ) -> UInt32? {
        let hotKeyId = nextCustomHotKeyId
        nextCustomHotKeyId += 1

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print(
                "HotKeyService: Failed to register custom hotkey. Status: \(status), KeyCode: \(keyCode), Mods: \(modifiers)"
            )
            return nil
        }

        customHotKeyRefs[hotKeyId] = hotKeyRef
        customHotKeyActions[hotKeyId] = (itemId, isExtension)
        customHotKeyConfigs[hotKeyId] = HotKeyConfig(keyCode: keyCode, modifiers: modifiers)

        print(
            "HotKeyService: Registered Custom HotKey (ID: \(hotKeyId), Code: \(keyCode), Mods: \(modifiers), Item: \(itemId), IsExt: \(isExtension))"
        )

        return hotKeyId
    }

    /// 注销自定义快捷键
    func unregisterCustomHotKey(hotKeyId: UInt32) {
        guard let ref = customHotKeyRefs[hotKeyId] else { return }

        UnregisterEventHotKey(ref)
        customHotKeyRefs.removeValue(forKey: hotKeyId)
        customHotKeyActions.removeValue(forKey: hotKeyId)
        customHotKeyConfigs.removeValue(forKey: hotKeyId)

        print("HotKeyService: Unregistered Custom HotKey (ID: \(hotKeyId))")
    }

    /// 注销所有自定义快捷键
    func unregisterAllCustomHotKeys() {
        for (hotKeyId, ref) in customHotKeyRefs {
            UnregisterEventHotKey(ref)
            print("HotKeyService: Unregistered Custom HotKey (ID: \(hotKeyId))")
        }
        customHotKeyRefs.removeAll()
        customHotKeyActions.removeAll()
        customHotKeyConfigs.removeAll()
    }

    // MARK: - 书签快捷键

    /// 注册书签扩展快捷键
    func registerBookmarkHotKey(keyCode: UInt32, modifiers: UInt32) {
        // 先注销旧的
        unregisterBookmarkHotKey()

        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: bookmarkHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            bookmarkHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered Bookmark HotKey (Code: \(keyCode), Mods: \(modifiers))")
        } else {
            print("HotKeyService: Failed to register bookmark hotkey. Status: \(status)")
        }
    }

    /// 注销书签扩展快捷键
    func unregisterBookmarkHotKey() {
        if let ref = bookmarkHotKeyRef {
            UnregisterEventHotKey(ref)
            bookmarkHotKeyRef = nil
            print("HotKeyService: Unregistered Bookmark HotKey")
        }
    }

    /// 加载书签快捷键设置
    func loadBookmarkHotKey() {
        let settings = BookmarkSettings.load()
        if settings.hotKeyCode != 0 {
            registerBookmarkHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    // MARK: - 2FA 快捷键

    /// 注册 2FA 扩展快捷键
    func register2FAHotKey(keyCode: UInt32, modifiers: UInt32) {
        // 先注销旧的
        unregister2FAHotKey()

        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: twoFAHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            twoFAHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered 2FA HotKey (Code: \(keyCode), Mods: \(modifiers))")
        } else {
            print("HotKeyService: Failed to register 2FA hotkey. Status: \(status)")
        }
    }

    /// 注销 2FA 扩展快捷键
    func unregister2FAHotKey() {
        if let ref = twoFAHotKeyRef {
            UnregisterEventHotKey(ref)
            twoFAHotKeyRef = nil
            print("HotKeyService: Unregistered 2FA HotKey")
        }
    }

    /// 加载 2FA 快捷键设置
    func load2FAHotKey() {
        let settings = TwoFactorAuthSettings.load()
        if settings.hotKeyCode != 0 {
            register2FAHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    // MARK: - 剪贴板快捷键

    /// 注册剪贴板快捷键
    func registerClipboardHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterClipboardHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: clipboardHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            clipboardHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered Clipboard HotKey (Code: \(keyCode), Mods: \(modifiers))")
        } else {
            print("HotKeyService: Failed to register clipboard hotkey. Status: \(status)")
        }
    }

    /// 注销剪贴板快捷键
    func unregisterClipboardHotKey() {
        if let ref = clipboardHotKeyRef {
            UnregisterEventHotKey(ref)
            clipboardHotKeyRef = nil
            print("HotKeyService: Unregistered Clipboard HotKey")
        }
    }

    /// 加载剪贴板快捷键设置
    func loadClipboardHotKey() {
        let settings = ClipboardSettings.load()
        if settings.hotKeyCode != 0 {
            registerClipboardHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    /// 注册纯文本粘贴快捷键
    func registerPlainTextPasteHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterPlainTextPasteHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: plainTextPasteHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            plainTextPasteHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered PlainTextPaste HotKey (Code: \(keyCode), Mods: \(modifiers))"
            )
        } else {
            print("HotKeyService: Failed to register plainTextPaste hotkey. Status: \(status)")
        }
    }

    /// 注销纯文本粘贴快捷键
    func unregisterPlainTextPasteHotKey() {
        if let ref = plainTextPasteHotKeyRef {
            UnregisterEventHotKey(ref)
            plainTextPasteHotKeyRef = nil
            print("HotKeyService: Unregistered PlainTextPaste HotKey")
        }
    }

    /// 加载纯文本粘贴快捷键设置
    func loadPlainTextPasteHotKey() {
        let settings = ClipboardSettings.load()
        if settings.plainTextHotKeyCode != 0 {
            registerPlainTextPasteHotKey(
                keyCode: settings.plainTextHotKeyCode, modifiers: settings.plainTextHotKeyModifiers)
        }
    }

    // MARK: - AI 翻译快捷键方法

    /// 注册选词翻译快捷键
    func registerTranslateSelectionHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterTranslateSelectionHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: translateSelectionHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            translateSelectionHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered TranslateSelection HotKey (Code: \(keyCode), Mods: \(modifiers))"
            )
        } else {
            print("HotKeyService: Failed to register translateSelection hotkey. Status: \(status)")
        }
    }

    /// 注销选词翻译快捷键
    func unregisterTranslateSelectionHotKey() {
        if let ref = translateSelectionHotKeyRef {
            UnregisterEventHotKey(ref)
            translateSelectionHotKeyRef = nil
            print("HotKeyService: Unregistered TranslateSelection HotKey")
        }
    }

    /// 注册输入翻译快捷键
    func registerTranslateInputHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterTranslateInputHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: translateInputHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            translateInputHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered TranslateInput HotKey (Code: \(keyCode), Mods: \(modifiers))"
            )
        } else {
            print("HotKeyService: Failed to register translateInput hotkey. Status: \(status)")
        }
    }

    /// 注销输入翻译快捷键
    func unregisterTranslateInputHotKey() {
        if let ref = translateInputHotKeyRef {
            UnregisterEventHotKey(ref)
            translateInputHotKeyRef = nil
            print("HotKeyService: Unregistered TranslateInput HotKey")
        }
    }

    /// 加载翻译快捷键设置
    func loadTranslateHotKeys() {
        let settings = AITranslateSettings.load()
        if settings.selectionHotKeyCode != 0 {
            registerTranslateSelectionHotKey(
                keyCode: settings.selectionHotKeyCode, modifiers: settings.selectionHotKeyModifiers)
        }
        if settings.inputHotKeyCode != 0 {
            registerTranslateInputHotKey(
                keyCode: settings.inputHotKeyCode, modifiers: settings.inputHotKeyModifiers)
        }
    }

    // MARK: - 表情包快捷键方法

    /// 注册表情包快捷键
    func registerMemeHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterMemeHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: memeHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            memeHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered Meme HotKey (Code: \(keyCode), Mods: \(modifiers))"
            )
        } else {
            print("HotKeyService: Failed to register meme hotkey. Status: \(status)")
        }
    }

    /// 注销表情包快捷键
    func unregisterMemeHotKey() {
        if let ref = memeHotKeyRef {
            UnregisterEventHotKey(ref)
            memeHotKeyRef = nil
            print("HotKeyService: Unregistered Meme HotKey")
        }
    }

    /// 加载表情包快捷键设置
    func loadMemeHotKey() {
        let settings = MemeSearchSettings.load()
        if settings.hotKeyCode != 0 {
            registerMemeHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    // MARK: - 表情包收藏快捷键

    /// 注册表情包收藏快捷键
    func registerFavoriteHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterFavoriteHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: favoriteHotKeyId)
        var hotKeyRef: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            favoriteHotKeyRef = hotKeyRef
            print(
                "HotKeyService: Registered Favorite HotKey (Code: \(keyCode), Mods: \(modifiers))"
            )
        } else {
            print("HotKeyService: Failed to register favorite hotkey. Status: \(status)")
        }
    }

    /// 注销表情包收藏快捷键
    func unregisterFavoriteHotKey() {
        if let ref = favoriteHotKeyRef {
            UnregisterEventHotKey(ref)
            favoriteHotKeyRef = nil
            print("HotKeyService: Unregistered Favorite HotKey")
        }
    }

    /// 加载表情包收藏快捷键设置
    func loadFavoriteHotKey() {
        let settings = MemeFavoriteSettings.load()
        if settings.hotKeyCode != 0 {
            registerFavoriteHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    // MARK: - 暂停/恢复快捷键（用于录制时）

    /// 暂停所有快捷键（录制时使用）
    func suspendAllHotKeys() {
        isSuspended = true

        // 暂停主快捷键
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
            print("HotKeyService: Suspended main hotkey")
        }

        // 暂停双击修饰键监听
        stopDoubleTapMonitoring()

        // 暂停所有自定义快捷键
        for (hotKeyId, ref) in customHotKeyRefs {
            UnregisterEventHotKey(ref)
            print("HotKeyService: Suspended custom hotkey (ID: \(hotKeyId))")
        }
        // 注意：不清除 customHotKeyActions 和 customHotKeyConfigs，以便恢复时使用
        customHotKeyRefs.removeAll()

        print("HotKeyService: All hotkeys suspended")
    }

    /// 恢复所有快捷键
    func resumeAllHotKeys() {
        isSuspended = false
        // 恢复主快捷键或双击修饰键
        if useDoubleTapModifier {
            startDoubleTapMonitoring()
            print("HotKeyService: Resumed double-tap modifier")
        } else if currentKeyCode != 0 && currentModifiers != 0 {
            // 使用 registerMainHotKey 方法来确保正确处理旧引用
            registerMainHotKey(keyCode: currentKeyCode, modifiers: currentModifiers)
            print("HotKeyService: Resumed main hotkey")
        }

        // 优先使用新的 ToolsConfig，如果没有数据则回退到 CustomItemsConfig
        let toolsConfig = ToolsConfig.load()
        if !toolsConfig.tools.isEmpty {
            reloadToolHotKeys(from: toolsConfig)
        } else {
            let config = CustomItemsConfig.load()
            reloadCustomHotKeys(from: config)
        }

        print("HotKeyService: All hotkeys resumed")
    }

    /// 从配置重新加载所有自定义快捷键（旧版本，兼容 CustomItemsConfig）
    func reloadCustomHotKeys(from config: CustomItemsConfig) {
        // 如果处于暂停状态（录制模式），不重新加载快捷键
        guard !isSuspended else {
            print("HotKeyService: Skipping reload - currently suspended")
            return
        }

        // 先注销所有现有的自定义快捷键
        unregisterAllCustomHotKeys()

        // 重新注册
        for item in config.customItems {
            if let openKey = item.openHotKey {
                registerCustomHotKey(
                    keyCode: openKey.keyCode,
                    modifiers: openKey.modifiers,
                    itemId: item.id,
                    isExtension: false
                )
            }
            if let extKey = item.extensionHotKey {
                registerCustomHotKey(
                    keyCode: extKey.keyCode,
                    modifiers: extKey.modifiers,
                    itemId: item.id,
                    isExtension: true
                )
            }
        }

        print(
            "HotKeyService: Reloaded \(customHotKeyRefs.count) custom hotkeys from CustomItemsConfig"
        )
    }

    /// 从 ToolsConfig 重新加载所有工具快捷键
    func reloadToolHotKeys(from config: ToolsConfig) {
        // 如果处于暂停状态（录制模式），不重新加载快捷键
        guard !isSuspended else {
            print("HotKeyService: Skipping reload - currently suspended")
            return
        }

        // 先注销所有现有的自定义快捷键
        unregisterAllCustomHotKeys()

        // 只为已启用的工具注册快捷键
        for tool in config.enabledTools {
            // 注册主快捷键
            if let hotKey = tool.hotKey {
                registerCustomHotKey(
                    keyCode: hotKey.keyCode,
                    modifiers: hotKey.modifiers,
                    itemId: tool.id,
                    isExtension: false
                )
            }

            // 注册扩展快捷键（IDE、网页直达 Query、实用工具）
            // ⚠️ 重要：修改快捷键相关功能时，必须确保所有支持扩展的工具类型都被注册！
            if tool.supportsExtension, let extKey = tool.extensionHotKey {
                registerCustomHotKey(
                    keyCode: extKey.keyCode,
                    modifiers: extKey.modifiers,
                    itemId: tool.id,
                    isExtension: true
                )
            }
        }

        print("HotKeyService: Reloaded \(customHotKeyRefs.count) tool hotkeys from ToolsConfig")
    }

    // MARK: - 冲突检测

    /// 检查快捷键是否冲突
    /// - Parameters:
    ///   - keyCode: 按键代码
    ///   - modifiers: 修饰键
    ///   - excludingItemId: 排除的项目 ID（用于编辑时排除自身）
    ///   - excludingIsExtension: 排除的快捷键类型
    ///   - excludingMainHotKey: 是否排除主快捷键检测
    /// - Returns: 冲突的描述，nil 表示无冲突
    func checkConflict(
        keyCode: UInt32, modifiers: UInt32, excludingItemId: UUID? = nil,
        excludingIsExtension: Bool? = nil, excludingMainHotKey: Bool = false
    ) -> String? {
        // 检查与主快捷键的冲突（除非排除）
        if !excludingMainHotKey && keyCode == currentKeyCode && modifiers == currentModifiers
            && !useDoubleTapModifier
        {
            return "启动快捷键"
        }

        // 直接从 ToolsConfig 读取所有已配置的快捷键进行冲突检测
        let toolsConfig = ToolsConfig.load()
        for tool in toolsConfig.tools {
            // 检查主快捷键
            if let hotKey = tool.hotKey,
                hotKey.keyCode == keyCode && hotKey.modifiers == modifiers
            {
                // 如果是同一个项目的同类型快捷键，跳过
                if let excludeId = excludingItemId,
                    let excludeIsExt = excludingIsExtension,
                    tool.id == excludeId && !excludeIsExt
                {
                    continue
                }
                return tool.name + " (打开)"
            }

            // 检查扩展快捷键（IDE、网页直达 Query、实用工具）
            // ⚠️ 重要：修改快捷键相关功能时，必须确保所有支持扩展的工具类型都被检测！
            if tool.supportsExtension, let extKey = tool.extensionHotKey,
                extKey.keyCode == keyCode && extKey.modifiers == modifiers
            {
                // 如果是同一个项目的同类型快捷键，跳过
                if let excludeId = excludingItemId,
                    let excludeIsExt = excludingIsExtension,
                    tool.id == excludeId && excludeIsExt
                {
                    continue
                }
                return tool.name + " (进入扩展)"
            }
        }

        // 回退检查 CustomItemsConfig（兼容旧数据）
        let itemsConfig = CustomItemsConfig.load()
        for item in itemsConfig.customItems {
            // 检查打开快捷键
            if let openKey = item.openHotKey,
                openKey.keyCode == keyCode && openKey.modifiers == modifiers
            {
                if let excludeId = excludingItemId,
                    let excludeIsExt = excludingIsExtension,
                    item.id == excludeId && !excludeIsExt
                {
                    continue
                }
                return item.name + " (打开)"
            }

            // 检查扩展快捷键
            if let extKey = item.extensionHotKey,
                extKey.keyCode == keyCode && extKey.modifiers == modifiers
            {
                if let excludeId = excludingItemId,
                    let excludeIsExt = excludingIsExtension,
                    item.id == excludeId && excludeIsExt
                {
                    continue
                }
                return item.name + " (进入扩展)"
            }
        }

        return nil
    }

    /// 检查快捷键冲突（用于高级扩展设置）
    /// - Parameters:
    ///   - keyCode: 按键码
    ///   - modifiers: 修饰键
    ///   - excludeType: 排除的类型（"bookmark" 或 "2fa"）
    /// - Returns: 冲突的描述，nil 表示无冲突
    func checkHotKeyConflict(keyCode: UInt32, modifiers: UInt32, excludeType: String?) -> String? {
        // 检查与主快捷键的冲突
        if keyCode == currentKeyCode && modifiers == currentModifiers && !useDoubleTapModifier {
            return "启动快捷键"
        }

        // 检查与书签快捷键的冲突
        if excludeType != "bookmark" {
            let bookmarkSettings = BookmarkSettings.load()
            if bookmarkSettings.hotKeyCode == keyCode
                && bookmarkSettings.hotKeyModifiers == modifiers
            {
                return "搜索书签"
            }
        }

        // 检查与 2FA 快捷键的冲突
        if excludeType != "2fa" {
            let twoFASettings = TwoFactorAuthSettings.load()
            if twoFASettings.hotKeyCode == keyCode && twoFASettings.hotKeyModifiers == modifiers {
                return "2FA 短信"
            }
        }

        // 检查与剪贴板快捷键的冲突
        if excludeType != "clipboard" {
            let clipboardSettings = ClipboardSettings.load()
            if clipboardSettings.hotKeyCode == keyCode
                && clipboardSettings.hotKeyModifiers == modifiers
            {
                return "剪贴板"
            }
        }

        // 检查与纯文本粘贴快捷键的冲突
        if excludeType != "plainTextPaste" {
            let clipboardSettings = ClipboardSettings.load()
            if clipboardSettings.plainTextHotKeyCode == keyCode
                && clipboardSettings.plainTextHotKeyModifiers == modifiers
            {
                return "纯文本粘贴"
            }
        }

        // 检查与选词翻译快捷键的冲突
        if excludeType != "translateSelection" {
            let translateSettings = AITranslateSettings.load()
            if translateSettings.selectionHotKeyCode == keyCode
                && translateSettings.selectionHotKeyModifiers == modifiers
            {
                return "选词翻译"
            }
        }

        // 检查与输入翻译快捷键的冲突
        if excludeType != "translateInput" {
            let translateSettings = AITranslateSettings.load()
            if translateSettings.inputHotKeyCode == keyCode
                && translateSettings.inputHotKeyModifiers == modifiers
            {
                return "输入翻译"
            }
        }

        // 检查与表情包快捷键的冲突
        if excludeType != "meme" {
            let memeSettings = MemeSearchSettings.load()
            if memeSettings.hotKeyCode == keyCode
                && memeSettings.hotKeyModifiers == modifiers
            {
                return "表情包"
            }
        }

        // 检查与表情包收藏快捷键的冲突
        if excludeType != "favorite" {
            let favoriteSettings = MemeFavoriteSettings.load()
            if favoriteSettings.hotKeyCode == keyCode
                && favoriteSettings.hotKeyModifiers == modifiers
            {
                return "表情收藏"
            }
        }

        // 检查与工具快捷键的冲突
        let toolsConfig = ToolsConfig.load()
        for tool in toolsConfig.tools {
            if let hotKey = tool.hotKey,
                hotKey.keyCode == keyCode && hotKey.modifiers == modifiers
            {
                return tool.name
            }
            if tool.supportsExtension, let extKey = tool.extensionHotKey,
                extKey.keyCode == keyCode && extKey.modifiers == modifiers
            {
                return tool.name + " (进入扩展)"
            }
        }

        return nil
    }

    // MARK: - 事件处理

    /// 内部事件处理方法
    fileprivate func handleEvent(_ event: EventRef?) -> OSStatus {
        guard let event = event else { return OSStatus(eventNotHandledErr) }

        var hotKeyID = EventHotKeyID()
        let error = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        if error == noErr && hotKeyID.signature == hotKeySignature {
            // 检查是否为主快捷键
            if hotKeyID.id == mainHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为书签快捷键
            if hotKeyID.id == bookmarkHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onBookmarkHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为 2FA 快捷键
            if hotKeyID.id == twoFAHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.on2FAHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为剪贴板快捷键
            if hotKeyID.id == clipboardHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onClipboardHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为纯文本粘贴快捷键
            if hotKeyID.id == plainTextPasteHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onPlainTextPasteHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为选词翻译快捷键
            if hotKeyID.id == translateSelectionHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onTranslateSelectionHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为输入翻译快捷键
            if hotKeyID.id == translateInputHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onTranslateInputHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为表情包快捷键
            if hotKeyID.id == memeHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onMemeHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为表情包收藏快捷键
            if hotKeyID.id == favoriteHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onFavoriteHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为自定义快捷键
            if let action = customHotKeyActions[hotKeyID.id] {
                DispatchQueue.main.async { [weak self] in
                    self?.onCustomHotKeyPressed?(action.0, action.1)
                }
                return noErr
            }
        }

        return OSStatus(eventNotHandledErr)
    }

    deinit {
        // 注销主快捷键
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
        }

        // 注销所有自定义快捷键
        for (_, ref) in customHotKeyRefs {
            UnregisterEventHotKey(ref)
        }

        // 移除事件处理程序
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

// MARK: - Helpers

private func byteAt(_ string: String, _ index: Int) -> UInt8 {
    let array = Array(string.utf8)
    guard index < array.count else { return 0 }
    return array[index]
}

extension HotKeyService {
    // Helper to convert NSEvent.ModifierFlags to Carbon modifiers
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }

    // Helper to convert Carbon modifiers to string for display
    static func displayString(for modifiers: UInt32, keyCode: UInt32) -> String {
        var string = ""
        if modifiers & UInt32(controlKey) != 0 { string += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { string += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { string += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { string += "⌘" }

        string += keyString(for: keyCode)
        return string
    }

    /// 获取修饰键的符号数组
    static func modifierSymbols(for modifiers: UInt32) -> [String] {
        var symbols: [String] = []
        if modifiers & UInt32(controlKey) != 0 { symbols.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { symbols.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { symbols.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { symbols.append("⌘") }
        return symbols
    }

    static func keyString(for keyCode: UInt32) -> String {
        // TISInputSource would be more accurate for localized keyboards,
        // but this manual mapping covers standard US ANSI layout.
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"

        // ANSI Letters
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"

        // ANSI Numbers
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        // Common Symbols
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"

        // Function Keys
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"

        default: return "?"
        }
    }
}
