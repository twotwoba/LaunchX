import Carbon
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }

            SearchSettingsView()
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }

            AliasShortcutSettingsView()
                .tabItem {
                    Label("别名与快捷键", systemImage: "command.square")
                }

            Text("Extensions")
                .tabItem {
                    Label("扩展", systemImage: "puzzlepiece")
                }
        }
        .frame(width: 700, height: 520)
        .padding()
        .onAppear {
            PanelManager.shared.hidePanel(deactivateApp: false)
        }
    }
}

struct GeneralSettingsView: View {
    // Window Mode persistence
    @AppStorage("defaultWindowMode") private var windowModeString: String = "full"

    // Launch at Login state
    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                // 1. Launch at Login
                HStack {
                    Text("登录时打开:")
                    Toggle("开启", isOn: $isLaunchAtLoginEnabled)
                        .toggleStyle(CheckboxToggleStyle())
                        .onChange(of: isLaunchAtLoginEnabled) { _, newValue in
                            updateLaunchAtLogin(enabled: newValue)
                        }
                        .onAppear {
                            checkLaunchAtLoginStatus()
                        }
                    Spacer()
                }

                // 2. HotKey Configuration
                HStack {
                    Text("启动快捷键:")
                    HotKeyRecorderView()
                    Spacer()
                }
            }

            Divider()
                .padding(.vertical, 10)

            Section {
                // 3. Default Window Mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("默认窗口模式:")

                    Picker("", selection: $windowModeString) {
                        Text("简约").tag("simple")
                        Text("完整").tag("full")
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .labelsHidden()

                    // Visual Representation
                    HStack(spacing: 30) {
                        VStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(radius: 1)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.8))
                                        .frame(height: 8)  // Search bar
                                    Spacer()
                                }
                                .padding(6)
                            }
                            .frame(width: 80, height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        windowModeString == "simple" ? Color.blue : Color.clear,
                                        lineWidth: 2)
                            )

                            Text("Simple")
                                .font(.caption)
                                .foregroundColor(
                                    windowModeString == "simple" ? .primary : .secondary)
                        }
                        .onTapGesture { windowModeString = "simple" }

                        VStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(radius: 1)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.8))
                                        .frame(height: 8)  // Search bar

                                    // List items
                                    ForEach(0..<3) { _ in
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(height: 4)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                            }
                            .frame(width: 80, height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        windowModeString == "full" ? Color.blue : Color.clear,
                                        lineWidth: 2)
                            )

                            Text("Full")
                                .font(.caption)
                                .foregroundColor(windowModeString == "full" ? .primary : .secondary)
                        }
                        .onTapGesture { windowModeString = "full" }
                    }
                    .padding(.top, 5)
                }
            }

            Divider()
                .padding(.vertical, 10)

            Section {
                PermissionSettingsView()
            }
        }
        .padding(20)
    }

    // MARK: - Launch at Login Logic

    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
                // Revert UI if failed
                checkLaunchAtLoginStatus()
            }
        }
    }
}

// MARK: - HotKey Recorder

struct HotKeyRecorderView: View {
    @ObservedObject var hotKeyService = HotKeyService.shared
    @State private var showPopover = false
    @State private var isHovered = false

    private var hasHotKey: Bool {
        hotKeyService.currentKeyCode != 0 || hotKeyService.useDoubleTapModifier
    }

    var body: some View {
        Button(action: {
            showPopover = true
        }) {
            Group {
                if hasHotKey {
                    // 已设置快捷键：显示按键帽样式
                    HStack(spacing: 2) {
                        if hotKeyService.useDoubleTapModifier {
                            // 显示双击修饰键
                            KeyCapViewSettings(text: hotKeyService.doubleTapModifier.symbol)
                            KeyCapViewSettings(text: hotKeyService.doubleTapModifier.symbol)
                        } else {
                            // 显示传统快捷键
                            ForEach(
                                HotKeyService.modifierSymbols(for: hotKeyService.currentModifiers),
                                id: \.self
                            ) { symbol in
                                KeyCapViewSettings(text: symbol)
                            }
                            KeyCapViewSettings(
                                text: HotKeyService.keyString(for: hotKeyService.currentKeyCode))
                        }
                    }
                } else {
                    Text("快捷键")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        (isHovered && !hasHotKey) ? Color.secondary.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $showPopover) {
            MainHotKeyRecorderPopover(isPresented: $showPopover)
        }
    }
}

// MARK: - 主快捷键录制弹窗

struct MainHotKeyRecorderPopover: View {
    @Binding var isPresented: Bool
    @ObservedObject var hotKeyService = HotKeyService.shared
    @State private var keyDownMonitor: Any?
    @State private var flagsMonitor: Any?

    // 双击修饰键检测
    @State private var lastModifierPressTime: Date?
    @State private var lastPressedModifier: DoubleTapModifier?
    @State private var previousFlags: NSEvent.ModifierFlags = []
    private let doubleTapInterval: TimeInterval = 0.3

    // 冲突检测
    @State private var conflictMessage: String?

    private var hasHotKey: Bool {
        hotKeyService.currentKeyCode != 0 || hotKeyService.useDoubleTapModifier
    }

    var body: some View {
        VStack(spacing: 12) {
            // 示例提示
            HStack(spacing: 4) {
                Text("例子")
                    .foregroundColor(.secondary)
                KeyCapViewLarge(text: "⌘")
                KeyCapViewLarge(text: "⇧")
                KeyCapViewLarge(text: "SPACE")
                Text("或")
                    .foregroundColor(.secondary)
                KeyCapViewLarge(text: "⌘")
                KeyCapViewLarge(text: "⌘")
            }
            .padding(.top, 8)

            // 提示文字或冲突信息
            if let conflict = conflictMessage {
                Text("快捷键已被「\(conflict)」使用")
                    .foregroundColor(.red)
                    .font(.system(size: 13))
            } else {
                Text("请输入快捷键或连续按两次修饰键...")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            // 已设置快捷键时显示当前快捷键和删除按钮
            if hasHotKey {
                HStack(spacing: 4) {
                    if hotKeyService.useDoubleTapModifier {
                        // 显示双击修饰键
                        KeyCapViewLarge(text: hotKeyService.doubleTapModifier.symbol)
                        KeyCapViewLarge(text: hotKeyService.doubleTapModifier.symbol)
                    } else {
                        // 显示传统快捷键
                        ForEach(
                            HotKeyService.modifierSymbols(for: hotKeyService.currentModifiers),
                            id: \.self
                        ) { symbol in
                            KeyCapViewLarge(text: symbol)
                        }
                        KeyCapViewLarge(
                            text: HotKeyService.keyString(for: hotKeyService.currentKeyCode))
                    }

                    // 删除按钮
                    Button {
                        hotKeyService.clearHotKey()
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: 280)
        .onAppear {
            // 暂停所有快捷键，以便录制
            hotKeyService.suspendAllHotKeys()
            startRecording()
        }
        .onDisappear {
            stopRecording()
            // 恢复所有快捷键
            hotKeyService.resumeAllHotKeys()
        }
    }

    private func startRecording() {
        // 重置双击检测状态
        lastModifierPressTime = nil
        lastPressedModifier = nil
        previousFlags = []
        conflictMessage = nil

        // 监听按键事件（传统快捷键）
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape 取消
            if event.keyCode == kVK_Escape {
                stopRecording()
                isPresented = false
                return nil
            }

            // Delete 清除快捷键
            if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
                hotKeyService.clearHotKey()
                stopRecording()
                isPresented = false
                return nil
            }

            // 必须有修饰键
            let modifiers = HotKeyService.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                return event
            }

            let keyCode = UInt32(event.keyCode)

            // 禁止使用 Cmd+, (系统设置快捷键)
            if keyCode == UInt32(kVK_ANSI_Comma) && modifiers == UInt32(cmdKey) {
                conflictMessage = "系统设置"
                return nil
            }

            // 检查冲突（排除当前主快捷键本身）
            if let conflict = hotKeyService.checkConflict(
                keyCode: keyCode, modifiers: modifiers, excludingMainHotKey: true)
            {
                conflictMessage = conflict
                return nil
            }

            // 无冲突，设置传统快捷键
            hotKeyService.registerHotKey(keyCode: keyCode, modifiers: modifiers)
            stopRecording()
            isPresented = false
            return nil
        }

        // 监听修饰键事件（双击修饰键）
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // 检测每个修饰键
        for modifier in DoubleTapModifier.allCases {
            let targetFlag = modifier.flag
            let wasPressed =
                !previousFlags.contains(targetFlag) && currentFlags.contains(targetFlag)
            let onlyTargetPressed =
                currentFlags.subtracting([.capsLock, .numericPad, .function]) == targetFlag

            if wasPressed && onlyTargetPressed {
                let now = Date()

                if let lastTime = lastModifierPressTime,
                    let lastModifier = lastPressedModifier,
                    lastModifier == modifier,
                    now.timeIntervalSince(lastTime) < doubleTapInterval
                {
                    // 双击检测成功，设置双击修饰键
                    hotKeyService.enableDoubleTapModifier(modifier)
                    stopRecording()
                    isPresented = false
                    return
                } else {
                    // 记录第一次按下
                    lastModifierPressTime = now
                    lastPressedModifier = modifier
                }
            }
        }

        // 如果同时按下多个修饰键，重置状态
        let modifierCount = [
            currentFlags.contains(.command),
            currentFlags.contains(.option),
            currentFlags.contains(.control),
            currentFlags.contains(.shift),
        ].filter { $0 }.count

        if modifierCount > 1 {
            lastModifierPressTime = nil
            lastPressedModifier = nil
        }

        previousFlags = currentFlags
    }

    private func stopRecording() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            self.keyDownMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            self.flagsMonitor = nil
        }
    }
}

// MARK: - 设置页按键帽视图

struct KeyCapViewSettings: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(4)
    }
}
