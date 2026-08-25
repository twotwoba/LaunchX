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

            ToolsSettingsView()
                .tabItem {
                    Label("工具管理", systemImage: "wrench.and.screwdriver")
                }

            AdvancedExtensionsView()
                .tabItem {
                    Label("高级扩展", systemImage: "sparkles")
                }

            PerformanceSettingsView()
                .tabItem {
                    Label("性能", systemImage: "chart.xyaxis.line")
                }
        }
        .frame(width: 700, height: 520)
        .padding()
        .onAppear {
            PanelManager.shared.hidePanel()

            // 设置窗可见期间开启权限轮询（2s，全部授予后自动停），关窗即停
            PermissionService.shared.startPeriodicCheck()

            // 配置设置窗口，使其能在全屏应用上显示并跟随到当前空间
            DispatchQueue.main.async {
                for window in NSApp.windows where window.isVisible {
                    // 找到设置窗口（排除搜索主面板和 1x1 的辅助窗口）
                    let className = String(describing: type(of: window))
                    if !className.contains("Panel") && window.frame.width >= 700 {
                        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                        // 确保设置窗口在全屏应用上方显示并移动到当前活跃空间
                        window.orderFrontRegardless()
                    }
                }
            }
        }
        .onDisappear {
            // 设置窗关闭：停权限轮询，平时保持零 timer
            PermissionService.shared.stopPeriodicCheck()
        }
    }
}

struct GeneralSettingsView: View {
    // Window Mode persistence
    @AppStorage("defaultWindowMode") private var windowModeString: String = "full"
    @AppStorage("enableLiquidGlass") private var enableLiquidGlass: Bool = true

    // Launch at Login state
    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // 1. Launch at Login
                HStack(spacing: 12) {
                    Text("登录时打开:")
                        .frame(width: 85, alignment: .leading)
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
                HStack(spacing: 12) {
                    Text("启动快捷键:")
                        .frame(width: 85, alignment: .leading)
                    HotKeyRecorderView()
                    Spacer()
                }

                Divider()
                    .padding(.vertical, 4)

                // 3. Default Window Mode
                VStack(alignment: .leading, spacing: 8) {
                    Text("默认窗口模式:")

                    // Visual cards (tappable, no radio buttons)
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

                            Text("简约")
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

                            Text("完整")
                                .font(.caption)
                                .foregroundColor(windowModeString == "full" ? .primary : .secondary)
                        }
                        .onTapGesture { windowModeString = "full" }
                    }
                    .padding(.top, 5)
                }

                if #available(macOS 26.0, *) {
                    HStack(spacing: 12) {
                        Text("液态玻璃:")
                            .frame(width: 85, alignment: .leading)
                        Toggle("开启", isOn: $enableLiquidGlass)
                            .toggleStyle(CheckboxToggleStyle())
                            .onChange(of: enableLiquidGlass) { _, _ in
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("enableLiquidGlassDidChange"),
                                    object: nil)
                            }
                        Spacer()
                    }
                    .padding(.top, 4)
                }

                // MARK: - Keyboard Remapping
                Divider()
                    .padding(.vertical, 4)

                KeyRemapSettingsView()

                Divider()
                    .padding(.vertical, 4)

                PermissionSettingsView()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
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

// MARK: - 性能设置视图

struct PerformanceSettingsView: View {
    @State private var statistics: DiskWriteStatistics?
    @State private var walStatistics: (walSize: Int64, dbSize: Int64, checkpointCount: Int)?
    @State private var settings = DiskWriteOptimizationSettings.shared
    @State private var refreshTimer: Timer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 磁盘写入统计
                GroupBox(label: Text("磁盘写入统计").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let stats = statistics {
                            // 健康度评分
                            HStack {
                                Text("健康度:")
                                    .frame(width: 100, alignment: .leading)
                                Text("\(stats.healthScore)分")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundColor(healthColor(score: stats.healthScore))
                                Text("(\(stats.healthStatus))")
                                    .foregroundColor(.secondary)
                                Spacer()
                            }

                            Divider()

                            // 统计数据
                            StatRow(label: "总写入量", value: stats.formattedTotalBytes)
                            StatRow(label: "当前速率", value: stats.formattedCurrentRate)
                            StatRow(label: "平均速率", value: stats.formattedAverageRate)
                            StatRow(label: "运行时长", value: stats.formattedUptime)

                            // WAL 统计
                            if let wal = walStatistics {
                                Divider()
                                StatRow(label: "WAL 文件大小", value: DiskWriteMonitor.shared.formatBytes(wal.walSize))
                                StatRow(label: "数据库大小", value: DiskWriteMonitor.shared.formatBytes(wal.dbSize))
                                StatRow(label: "Checkpoint 次数", value: "\(wal.checkpointCount)")
                            }

                            // 优化建议
                            if !stats.recommendations.isEmpty {
                                Divider()
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("优化建议:")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    ForEach(stats.recommendations, id: \.self) { recommendation in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text("•")
                                            Text(recommendation)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            // 重置按钮
                            HStack {
                                Spacer()
                                Button("重置统计") {
                                    DiskWriteMonitor.shared.reset()
                                    refreshStatistics()
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text("正在加载统计数据...")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }

                // 优化开关
                GroupBox(label: Text("优化选项").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("剪贴板防抖动保存", isOn: Binding(
                            get: { settings.debounceClipboardSaveEnabled },
                            set: { newValue in
                                settings.debounceClipboardSaveEnabled = newValue
                                settings.save()
                                self.settings = DiskWriteOptimizationSettings.shared
                            }
                        ))
                        Text("延迟 \(Int(settings.clipboardDebounceInterval)) 秒保存，合并多次操作")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("WAL Checkpoint 优化", isOn: Binding(
                            get: { settings.walOptimizationEnabled },
                            set: { newValue in
                                settings.walOptimizationEnabled = newValue
                                settings.save()
                                self.settings = DiskWriteOptimizationSettings.shared
                            }
                        ))
                        Text("减少数据库 checkpoint 频率，降低磁盘写入")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("FSEvents 批量处理", isOn: Binding(
                            get: { settings.fsEventsBatchProcessingEnabled },
                            set: { newValue in
                                settings.fsEventsBatchProcessingEnabled = newValue
                                settings.save()
                                self.settings = DiskWriteOptimizationSettings.shared
                            }
                        ))
                        Text("批量处理文件系统事件，减少数据库写入次数")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Divider()

                        Toggle("性能日志", isOn: Binding(
                            get: { settings.performanceLoggingEnabled },
                            set: { newValue in
                                settings.performanceLoggingEnabled = newValue
                                settings.save()
                                self.settings = DiskWriteOptimizationSettings.shared
                            }
                        ))
                        Text("记录详细的性能日志（用于调试）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            .padding()
        }
        .onAppear {
            refreshStatistics()
            startRefreshTimer()
        }
        .onDisappear {
            stopRefreshTimer()
        }
    }

    private func refreshStatistics() {
        statistics = DiskWriteMonitor.shared.getStatistics()
        walStatistics = IndexDatabase.shared.getWALStatistics()
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            refreshStatistics()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func healthColor(score: Int) -> Color {
        if score >= 80 {
            return .green
        } else if score >= 60 {
            return .blue
        } else if score >= 40 {
            return .orange
        } else {
            return .red
        }
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label + ":")
                .frame(width: 100, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
    }
}

// MARK: - 键盘映射设置视图

struct KeyRemapSettingsView: View {
    @AppStorage("keyRemapHyperKey") private var hyperKey = false
    @AppStorage("keyRemapQuoteSwap") private var quoteSwap = false

    @State private var hasAccessibilityPermission = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("键盘映射:")
                    .frame(width: 85, alignment: .leading)

                if hasAccessibilityPermission {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            Toggle("Hyper (右⌘)", isOn: $hyperKey)
                                .toggleStyle(CheckboxToggleStyle())
                                .onChange(of: hyperKey) { _, newValue in
                                    KeyRemapService.shared.hyperKeyEnabled = newValue
                                }

                            Toggle("引号互换", isOn: $quoteSwap)
                                .toggleStyle(CheckboxToggleStyle())
                                .onChange(of: quoteSwap) { _, newValue in
                                    KeyRemapService.shared.quoteSwapEnabled = newValue
                                }

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 4) {
                        Text("键盘映射需要")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Button("辅助功能权限") {
                            openAccessibilityPreferences()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .underline()
                    }
                }
            }
        }
        .onAppear {
            hasAccessibilityPermission = KeyRemapService.shared.hasAccessibilityPermission

            if hasAccessibilityPermission {
                KeyRemapService.shared.applySettings(hyper: hyperKey, quote: quoteSwap)
            }
        }
    }

    private func openAccessibilityPreferences() {
        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 设置页按键帽视图

