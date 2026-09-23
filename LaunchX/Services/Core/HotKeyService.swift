import Carbon
import Cocoa
import Combine

import Carbon
import Cocoa
import Combine

// C-convention callback function for the event handler
func globalHotKeyHandler(
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

    var mainHotKeyRef: EventHotKeyRef?
    let mainHotKeyId: UInt32 = 1

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
    var lastModifierPressTime: Date?
    var lastPressedModifier: DoubleTapModifier?
    var globalFlagsMonitor: Any?
    var localFlagsMonitor: Any?
    let doubleTapInterval: TimeInterval = 0.3  // 双击间隔阈值
    var previousFlags: NSEvent.ModifierFlags = []

    // 双击唤起的 flagsChanged 风暴保护（Caps Lock 回环时暂停监听）
    // 注意：这些属性需在 HotKeyService+CustomHotKeys.swift 的 extension 中访问，
    // 故不能用 private（private 仅限同文件），用默认 internal。
    let doubleTapStormDetector = FlagsStormDetector()
    var doubleTapStormPaused = false
    var doubleTapStormResumeWork: DispatchWorkItem?
    let doubleTapStormPauseSeconds: TimeInterval = 30

    // MARK: - 自定义快捷键

    /// 自定义快捷键触发回调 (itemId, isExtension)
    var onCustomHotKeyPressed: ((UUID, Bool) -> Void)?

    /// 自定义快捷键引用: hotKeyId -> EventHotKeyRef
    var customHotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// 自定义快捷键动作: hotKeyId -> (itemId, isExtension)
    var customHotKeyActions: [UInt32: (UUID, Bool)] = [:]
    /// 快捷键配置缓存: hotKeyId -> HotKeyConfig（用于冲突检测）
    var customHotKeyConfigs: [UInt32: HotKeyConfig] = [:]
    /// 下一个可用的快捷键 ID（从 100 开始，避免与主快捷键冲突）
    var nextCustomHotKeyId: UInt32 = 100

    // MARK: - 书签扩展快捷键

    /// 书签快捷键触发回调
    var onBookmarkHotKeyPressed: (() -> Void)?
    /// 书签快捷键引用
    var bookmarkHotKeyRef: EventHotKeyRef?
    /// 书签快捷键 ID
    let bookmarkHotKeyId: UInt32 = 2

    /// 2FA 快捷键触发回调
    var on2FAHotKeyPressed: (() -> Void)?
    /// 2FA 快捷键引用
    var twoFAHotKeyRef: EventHotKeyRef?
    /// 2FA 快捷键 ID
    let twoFAHotKeyId: UInt32 = 3

    // MARK: - 剪贴板扩展快捷键

    /// 剪贴板快捷键触发回调
    var onClipboardHotKeyPressed: (() -> Void)?
    /// 纯文本粘贴快捷键触发回调
    var onPlainTextPasteHotKeyPressed: (() -> Void)?
    /// 剪贴板快捷键引用
    var clipboardHotKeyRef: EventHotKeyRef?
    /// 纯文本粘贴快捷键引用
    var plainTextPasteHotKeyRef: EventHotKeyRef?
    /// 剪贴板快捷键 ID
    let clipboardHotKeyId: UInt32 = 4
    /// 纯文本粘贴快捷键 ID
    let plainTextPasteHotKeyId: UInt32 = 5

    // MARK: - AI 翻译快捷键

    /// 选词翻译快捷键触发回调
    var onTranslateSelectionHotKeyPressed: (() -> Void)?
    /// 输入翻译快捷键触发回调
    var onTranslateInputHotKeyPressed: (() -> Void)?
    /// 选词翻译快捷键引用
    var translateSelectionHotKeyRef: EventHotKeyRef?
    /// 输入翻译快捷键引用
    var translateInputHotKeyRef: EventHotKeyRef?
    /// 选词翻译快捷键 ID
    let translateSelectionHotKeyId: UInt32 = 6
    /// 输入翻译快捷键 ID
    let translateInputHotKeyId: UInt32 = 7

    /// Claude Code Switcher 快捷键触发回调
    var onClaudeCodeHotKeyPressed: (() -> Void)?
    /// Claude Code Switcher 快捷键引用
    var claudeCodeHotKeyRef: EventHotKeyRef?
    /// Claude Code Switcher 快捷键 ID
    let claudeCodeHotKeyId: UInt32 = 8

    /// Codex Switcher 快捷键触发回调
    var onCodexHotKeyPressed: (() -> Void)?
    /// Codex Switcher 快捷键引用
    var codexHotKeyRef: EventHotKeyRef?
    /// Codex Switcher 快捷键 ID
    let codexHotKeyId: UInt32 = 9

    // MARK: - 私有属性

    let hotKeySignature: OSType
    var eventHandlerRef: EventHandlerRef?

    /// 是否处于录制模式（暂停状态）
    var isSuspended: Bool = false

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

    @objc func handleConfigImport() {
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
            self.loadClaudeCodeHotKey()
        }
    }

    // MARK: - 事件处理

    /// 内部事件处理方法
    func handleEvent(_ event: EventRef?) -> OSStatus {
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

            // 检查是否为 Claude Code Switcher 快捷键
            if hotKeyID.id == claudeCodeHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onClaudeCodeHotKeyPressed?()
                }
                return noErr
            }

            // 检查是否为 Codex Switcher 快捷键
            if hotKeyID.id == codexHotKeyId {
                DispatchQueue.main.async { [weak self] in
                    self?.onCodexHotKeyPressed?()
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

func byteAt(_ string: String, _ index: Int) -> UInt8 {
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
