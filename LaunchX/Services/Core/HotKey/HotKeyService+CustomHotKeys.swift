import Carbon
import Cocoa

// MARK: - 自定义快捷键、书签、2FA、剪贴板、AI翻译方法

extension HotKeyService {
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
    func disableDoubleTapModifier() {
        stopDoubleTapMonitoring()
        lastModifierPressTime = nil
        lastPressedModifier = nil
        previousFlags = []
    }

    /// 开始监听双击修饰键
    func startDoubleTapMonitoring() {
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
    func stopDoubleTapMonitoring() {
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
    }

    /// 风暴保护：检测到 flagsChanged 风暴时，临时停止双击监听一段时间。
    /// 运行在主线程（NSEvent monitor 回调），removeMonitor / asyncAfter 均安全。
    private func pauseDoubleTapForStorm() {
        guard !doubleTapStormPaused else { return }
        doubleTapStormPaused = true
        doubleTapStormDetector.reset()
        stopDoubleTapMonitoring()
        print("HotKeyService: ⚠️ 检测到 flagsChanged 风暴，暂停双击唤起监听 \(Int(doubleTapStormPauseSeconds))s")

        let work = DispatchWorkItem { [weak self] in
            self?.resumeDoubleTapFromStorm()
        }
        doubleTapStormResumeWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + doubleTapStormPauseSeconds, execute: work)
    }

    private func resumeDoubleTapFromStorm() {
        doubleTapStormPaused = false
        doubleTapStormResumeWork = nil
        guard useDoubleTapModifier else { return }
        startDoubleTapMonitoring()
        print("HotKeyService: 风暴暂停结束，恢复双击唤起监听")
    }

    /// 处理修饰键变化事件
    func handleFlagsChanged(_ event: NSEvent) {
        // 风暴保护：高频 flagsChanged（疑似 Caps Lock 输入法切换遥测回环）时，
        // 主动暂停双击唤起监听，避免监听回调持续堆积在卡死的主线程上。
        if doubleTapStormDetector.recordAndCheck() {
            pauseDoubleTapForStorm()
        }

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

    // MARK: - Claude Code Switcher 快捷键

    /// 注册 Claude Code Switcher 快捷键
    func registerClaudeCodeHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterClaudeCodeHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: claudeCodeHotKeyId)
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
            claudeCodeHotKeyRef = hotKeyRef
            print("HotKeyService: Registered ClaudeCode HotKey (Code: \(keyCode), Mods: \(modifiers))")
        } else {
            print("HotKeyService: Failed to register ClaudeCode hotkey. Status: \(status)")
        }
    }

    /// 注销 Claude Code Switcher 快捷键
    func unregisterClaudeCodeHotKey() {
        if let ref = claudeCodeHotKeyRef {
            UnregisterEventHotKey(ref)
            claudeCodeHotKeyRef = nil
            print("HotKeyService: Unregistered ClaudeCode HotKey")
        }
    }

    /// 加载 Claude Code Switcher 快捷键设置
    func loadClaudeCodeHotKey() {
        let settings = ClaudeCodeSwitcherSettings.load()
        if settings.hotKeyCode != 0 {
            registerClaudeCodeHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

    // MARK: - Codex Switcher 快捷键

    /// 注册 Codex Switcher 快捷键
    func registerCodexHotKey(keyCode: UInt32, modifiers: UInt32) {
        unregisterCodexHotKey()
        guard keyCode != 0 else { return }

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: codexHotKeyId)
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
            codexHotKeyRef = hotKeyRef
            print("HotKeyService: Registered Codex HotKey (Code: \(keyCode), Mods: \(modifiers))")
        } else {
            print("HotKeyService: Failed to register Codex hotkey. Status: \(status)")
        }
    }

    /// 注销 Codex Switcher 快捷键
    func unregisterCodexHotKey() {
        if let ref = codexHotKeyRef {
            UnregisterEventHotKey(ref)
            codexHotKeyRef = nil
            print("HotKeyService: Unregistered Codex HotKey")
        }
    }

    /// 加载 Codex Switcher 快捷键设置
    func loadCodexHotKey() {
        let settings = CodexSwitcherSettings.load()
        if settings.hotKeyCode != 0 {
            registerCodexHotKey(
                keyCode: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        }
    }

}
