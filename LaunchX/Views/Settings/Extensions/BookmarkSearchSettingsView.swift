import SwiftUI

struct BookmarkSearchSettingsView: View {
    @State private var settings = BookmarkSettings.load()
    @State private var bookmarkCount: Int = 0
    @State private var safariAccessible: Bool = true
    @State private var showHotKeyPopover: Bool = false
    @State private var selectedOption: BookmarkOpenWithOption = .special(.defaultBrowser)

    private let labelWidth: CGFloat = 140

    private var availableOpenWithOptions: [BookmarkOpenWithOption] {
        var options: [BookmarkOpenWithOption] = [
            .special(.bookmarkBrowser),
            .special(.defaultBrowser)
        ]

        for source in BookmarkSource.allCases where source.isInstalled {
            options.append(.browser(source))
        }

        return options
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SettingsHeaderStyle.iconTitleSpacing) {
                    Image(systemName: AdvancedExtensionType.bookmarkSearch.sfSymbolName)
                        .font(.system(size: SettingsHeaderStyle.iconSize))
                        .foregroundColor(AdvancedExtensionType.bookmarkSearch.iconColor)
                        .frame(width: SettingsHeaderStyle.iconFrameSize, height: SettingsHeaderStyle.iconFrameSize)
                    Text("搜索书签")
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
                            exampleKey: "B",
                            onSave: { settings.save() },
                            onUnregister: { HotKeyService.shared.unregisterBookmarkHotKey() },
                            onRegister: { keyCode, modifiers in
                                HotKeyService.shared.registerBookmarkHotKey(keyCode: keyCode, modifiers: modifiers)
                            },
                            checkConflict: { keyCode, modifiers in
                                HotKeyService.shared.checkConflict(
                                    keyCode: keyCode,
                                    modifiers: modifiers,
                                    excludingMainHotKey: false
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
                    TextField("bk", text: $settings.alias)
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
                    Text("打开浏览器:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: $selectedOption) {
                        ForEach(availableOpenWithOptions, id: \.id) { option in
                            HStack(spacing: 6) {
                                Image(nsImage: ImageUtils.resizeIcon(option.icon, to: 16))
                                Text(option.displayName)
                            }
                            .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                    .onChange(of: selectedOption) { _, newValue in
                        settings.openWith = newValue.toBookmarkOpenWith()
                        settings.save()
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider()
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text("搜索浏览器")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(BookmarkSource.allCases.filter { $0.isInstalled }, id: \.self) { source in
                        BrowserToggleRow(
                            source: source,
                            isEnabled: settings.enabledSources.contains(source),
                            isAccessible: source == .safari ? safariAccessible : true
                        ) { enabled in
                            updateSourceEnabled(source, enabled: enabled)
                        }
                    }

                    HStack {
                        Text("已索引书签: \(bookmarkCount) 个")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("刷新") {
                            refreshBookmarks()
                        }
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
                .padding(20)

                if !safariAccessible {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("需要完全磁盘访问权限才能读取 Safari 书签")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("打开设置") {
                            openFullDiskAccessSettings()
                        }
                        .font(.caption)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal, 20)
                }

                Spacer()
            }
        }
        .onAppear {
            checkAccess()
            refreshBookmarks()
            selectedOption = BookmarkOpenWithOption.from(settings.openWith)
        }
    }

    private func updateSourceEnabled(_ source: BookmarkSource, enabled: Bool) {
        if enabled {
            if !settings.enabledSources.contains(source) {
                settings.enabledSources.append(source)
            }
        } else {
            settings.enabledSources.removeAll { $0 == source }
        }
        settings.save()
        refreshBookmarks()
    }

    private func checkAccess() {
        safariAccessible = BookmarkService.shared.checkFullDiskAccess()
    }

    private func refreshBookmarks() {
        BookmarkService.shared.clearCache()
        let bookmarks = BookmarkService.shared.getAllBookmarks(forceReload: true)
        bookmarkCount = bookmarks.count
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        {
            AppOpener.open(url)
        }
    }
}

struct BrowserToggleRow: View {
    let source: BookmarkSource
    let isEnabled: Bool
    let isAccessible: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { isEnabled },
                    set: { onToggle($0) }
                )
            )
            .toggleStyle(.checkbox)
            .disabled(!isAccessible)

            Image(nsImage: source.icon)

            Text(source.displayName)
                .font(.system(size: 13))
                .opacity(isAccessible ? 1 : 0.5)

            if !isAccessible {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
