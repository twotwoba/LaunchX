import AppKit
import SwiftUI

enum AdvancedExtensionType: String, CaseIterable, Identifiable {
    case clipboard = "剪贴板"
    case snippet = "Snippet"
    case aiTranslate = "AI 翻译"
    case bookmarkSearch = "搜索书签"
    case twoFactorAuth = "2FA 短信"
    case reminders = "提醒事项"
    case terminal = "终端"
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    private static var isMacOS26OrLater: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    static var availableCases: [AdvancedExtensionType] {
        if isMacOS26OrLater {
            return allCases.filter { $0 != .twoFactorAuth }
        }
        return allCases
    }

    /// 官方品牌 logo 的 asset 名（若有），优先于 SF Symbol 显示
    var iconImageName: String? {
        switch self {
        case .claudeCode: return "ClaudeLogo"
        case .codex: return "OpenAILogo"
        default: return nil
        }
    }

    /// macOS 自带应用的 bundle id（若用其 App 图标作为侧边栏图标）。优先级高于 SF Symbol，
    /// 解析失败（如应用未安装）时自动回退到 SF Symbol 渐变方块。
    var systemAppBundleId: String? {
        switch self {
        case .reminders: return "com.apple.reminders"
        case .terminal: return "com.apple.Terminal"
        default: return nil
        }
    }

    /// 系统应用图标缓存，避免侧边栏每次渲染都查 LaunchServices
    private static let appIconCache = NSCache<NSString, NSImage>()

    /// 按 bundle id 解析系统应用图标（带缓存）
    static func systemAppIcon(forBundleId bundleId: String) -> NSImage? {
        if let cached = appIconCache.object(forKey: bundleId as NSString) {
            return cached
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        appIconCache.setObject(icon, forKey: bundleId as NSString)
        return icon
    }

    var sfSymbolName: String {
        switch self {
        case .clipboard: return "doc.on.clipboard.fill"
        case .snippet: return "chevron.left.forwardslash.chevron.right"
        case .aiTranslate: return "character.bubble.fill"
        case .bookmarkSearch: return "bookmark.fill"
        case .twoFactorAuth: return "lock.shield.fill"
        case .terminal: return "terminal.fill"
        case .reminders: return "checklist"
        case .claudeCode: return "cpu"
        case .codex: return "terminal"
        }
    }

    var iconColor: Color {
        switch self {
        case .clipboard: return Color(red: 230/255, green: 194/255, blue: 124/255)  // #E6C27C
        case .snippet: return .orange
        case .aiTranslate: return .indigo
        case .bookmarkSearch: return .pink
        case .twoFactorAuth: return .green
        case .terminal: return Color(red: 0.22, green: 0.22, blue: 0.24)
        case .reminders: return .purple
        case .claudeCode: return .brown
        case .codex: return .green
        }
    }
}

struct AdvancedExtensionsView: View {
    @State private var selectedExtension: AdvancedExtensionType = .clipboard

    var body: some View {
        HSplitView {
            extensionList
                .frame(minWidth: 180, maxWidth: 200)

            extensionSettings
                .frame(minWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var extensionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AdvancedExtensionType.availableCases) { type in
                ExtensionSidebarItem(
                    type: type,
                    isSelected: selectedExtension == type
                ) {
                    selectedExtension = type
                }
            }
            Spacer()
            Divider()
                .padding(.horizontal, 8)
            HStack(spacing: 8) {
                Button(action: {
                    BackupService.shared.exportConfiguration()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                        Text("导出")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)

                Button(action: {
                    BackupService.shared.importConfiguration()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11))
                        Text("导入")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusable(false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .padding(.top, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var extensionSettings: some View {
        switch selectedExtension {
        case .bookmarkSearch:
            BookmarkSearchSettingsView()
        case .clipboard:
            ClipboardSettingsView()
        case .snippet:
            SnippetSettingsView()
        case .twoFactorAuth:
            TwoFactorAuthSettingsView()
        case .aiTranslate:
            AITranslateSettingsView()
        case .terminal:
            TerminalSettingsView()
        case .reminders:
            RemindersSettingsView()
        case .claudeCode:
            ClaudeCodeSettingsView()
        case .codex:
            CodexMainSettingsView()
        }
    }
}

struct ExtensionSidebarItem: View {
    let iconImageName: String?
    let sfSymbolName: String
    let iconColor: Color
    let systemAppIcon: NSImage?
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(
        type: AdvancedExtensionType,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.iconImageName = type.iconImageName
        self.sfSymbolName = type.sfSymbolName
        self.iconColor = type.iconColor
        self.systemAppIcon = type.systemAppBundleId.flatMap {
            AdvancedExtensionType.systemAppIcon(forBundleId: $0)
        }
        self.title = type.rawValue
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                iconView
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .padding(.horizontal, 8)
    }

    /// 侧边栏图标：品牌 logo 直接展示；功能项用「渐变圆角方块 + 白色 SF Symbol」，
    /// 使其视觉权重与品牌 logo 接近，整体更精致统一。两类图标统一放在 20×20 容器中，
    /// 保证多行之间的文字左边缘对齐。
    @ViewBuilder
    private var iconView: some View {
        if let imageName = iconImageName, let logo = NSImage(named: imageName) {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 20, height: 20)
        } else if let appIcon = systemAppIcon {
            // macOS 自带应用图标（提醒事项 / 终端）：按 bundle id 取真实 App 图标，
            // 与品牌 logo 同样以图片方式渲染，比 SF Symbol 更精致。
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [iconColor.opacity(0.82), iconColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: sfSymbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
        }
    }
}

#Preview {
    AdvancedExtensionsView()
        .frame(width: 700, height: 500)
}
