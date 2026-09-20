import SwiftUI

struct TwoFactorAuthSettingsView: View {
    @State private var settings = TwoFactorAuthSettings.load()
    @State private var showHotKeyPopover = false
    @State private var hasFullDiskAccess = false
    @State private var recentCodesCount = 0

    private let labelWidth: CGFloat = 140

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SettingsHeaderStyle.iconTitleSpacing) {
                    Image(systemName: AdvancedExtensionType.twoFactorAuth.sfSymbolName)
                        .font(.system(size: SettingsHeaderStyle.iconSize))
                        .foregroundColor(AdvancedExtensionType.twoFactorAuth.iconColor)
                        .frame(width: SettingsHeaderStyle.iconFrameSize, height: SettingsHeaderStyle.iconFrameSize)
                    Text("2FA 短信")
                        .font(SettingsHeaderStyle.titleFont)
                        .fontWeight(SettingsHeaderStyle.titleFontWeight)
                    Spacer()

                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: settings.isEnabled) { _, _ in
                            settings.save()
                        }
                }
                .padding(.horizontal, SettingsHeaderStyle.horizontalPadding)
                .padding(.top, SettingsHeaderStyle.topPadding)
                .padding(.bottom, SettingsHeaderStyle.bottomPadding)

                Divider()

                HStack {
                    Text("直接打开扩展快捷键:")
                        .frame(width: labelWidth, alignment: .trailing)
                    ExtensionHotKeyButton(
                        keyCode: $settings.hotKeyCode,
                        modifiers: $settings.hotKeyModifiers,
                        showPopover: $showHotKeyPopover
                    )
                    .popover(isPresented: $showHotKeyPopover) {
                        ExtensionHotKeyRecorderPopover(
                            keyCode: $settings.hotKeyCode,
                            modifiers: $settings.hotKeyModifiers,
                            isPresented: $showHotKeyPopover,
                            exampleKey: "2",
                            onSave: { settings.save() },
                            onUnregister: { HotKeyService.shared.unregister2FAHotKey() },
                            onRegister: { keyCode, modifiers in
                                HotKeyService.shared.register2FAHotKey(keyCode: keyCode, modifiers: modifiers)
                            },
                            checkConflict: { keyCode, modifiers in
                                HotKeyService.shared.checkHotKeyConflict(
                                    keyCode: keyCode,
                                    modifiers: modifiers,
                                    excludeType: "2fa"
                                )
                            }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                HStack {
                    Text("别名:")
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("2fa", text: $settings.alias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onChange(of: settings.alias) { _, _ in
                            settings.save()
                        }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                HStack {
                    Text("搜索时间范围:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: $settings.timeSpanMinutes) {
                        Text("最近 5 分钟").tag(5)
                        Text("最近 10 分钟").tag(10)
                        Text("最近 30 分钟").tag(30)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .onChange(of: settings.timeSpanMinutes) { _, _ in
                        settings.save()
                        refreshCodesCount()
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                HStack {
                    Text("复制后删除短信:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Toggle("", isOn: $settings.deleteAfterCopy)
                        .toggleStyle(.switch)
                        .onChange(of: settings.deleteAfterCopy) { _, _ in
                            settings.save()
                        }
                    Text("因苹果限制，做不到无感删除，复制后屏幕上会有2s的自动操作，且该操作将删除该发送者的整个对话！")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("权限状态")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack(spacing: 8) {
                        Image(
                            systemName: hasFullDiskAccess
                                ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundColor(hasFullDiskAccess ? .green : .red)
                        Text("完全磁盘访问")
                            .font(.system(size: 13))
                        if !hasFullDiskAccess {
                            Spacer()
                            Button("授权") {
                                openFullDiskAccessSettings()
                            }
                            .font(.caption)
                        }
                    }

                    if hasFullDiskAccess {
                        HStack {
                            Text("已找到验证码: \(recentCodesCount) 个")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("刷新") {
                                refreshCodesCount()
                            }
                            .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(20)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("iPhone 短信转发设置")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 8) {
                        SetupStepRow(step: 1, text: "确保 iPhone 和 Mac 登录同一 Apple ID")
                        SetupStepRow(step: 2, text: "iPhone: 设置 → 信息 → 短信转发")
                        SetupStepRow(step: 3, text: "开启此 Mac 的短信转发开关")
                        SetupStepRow(step: 4, text: "Mac: 打开「信息」应用，确保已登录")
                    }

                    Button("打开「信息」应用") {
                        if let url = URL(string: "messages://") {
                            AppOpener.open(url)
                        }
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
                .padding(20)

                Spacer()
            }
        }
        .onAppear {
            checkPermissions()
            refreshCodesCount()
        }
    }

    private func checkPermissions() {
        hasFullDiskAccess = TwoFactorAuthService.shared.checkFullDiskAccess()
    }

    private func refreshCodesCount() {
        guard hasFullDiskAccess else {
            recentCodesCount = 0
            return
        }
        let codes = TwoFactorAuthService.shared.getRecentCodes(
            timeSpanMinutes: settings.timeSpanMinutes)
        recentCodesCount = codes.count
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        {
            AppOpener.open(url)
        }
    }
}

struct SetupStepRow: View {
    let step: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(step).")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
