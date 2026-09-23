import AppKit
import Foundation

// MARK: - Reminder Item Model

struct ReminderItem: Identifiable, Hashable {
    let id: String
    let title: String
    let dueDate: Date?
    let isCompleted: Bool
    let priority: Int  // 0: None, 1: High (!!!), 5: Medium (!!), 9: Low (!)
    let listTitle: String
    let listColor: NSColor?
    let notes: String?
    let url: URL?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct SearchResult: Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String
    var icon: NSImage
    let isDirectory: Bool
    var displayAlias: String?  // 用于显示的别名
    let isWebLink: Bool  // 是否为网页直达
    let isUtility: Bool  // 是否为实用工具
    let isSystemCommand: Bool  // 是否为系统命令
    let isBookmark: Bool  // 是否为书签
    let bookmarkSource: String?  // 书签来源（Safari/Chrome）
    let isBookmarkEntry: Bool  // 是否为书签搜索入口（通过别名进入）
    let is2FACode: Bool  // 是否为 2FA 验证码
    let is2FAEntry: Bool  // 是否为 2FA 入口（通过别名进入）
    let isMemeEntry: Bool  // 是否为表情包入口（通过别名进入）
    let isFavoriteEntry: Bool  // 是否为表情包收藏入口（通过别名进入）
    let supportsQueryExtension: Bool  // 是否支持 query 扩展
    let defaultUrl: String?  // 默认 URL（用于 query 扩展）
    let isSectionHeader: Bool  // 是否为分组标题
    let isReminder: Bool  // 是否为提醒事项
    let reminderIdentifier: String?  // 提醒事项唯一标识符
    let reminderColor: NSColor?  // 提醒事项列表颜色
    let reminderURL: URL?  // 提醒事项关联的 URL
    let processStats: String?  // 进程统计信息（CPU、内存等，靠右显示）

    // Claude Code Switcher 相关字段
    let isClaudeCodeEntry: Bool  // 是否为 Claude Code Switcher 入口
    let isCodexEntry: Bool  // 是否为 Codex Switcher 入口
    let isClaudeCodeItem: Bool  // 是否为 Claude Code Switcher 子项（Provider/MCP/Skill）
    let claudeCodeItemType: ClaudeCodeItemType?  // 子项类型
    let claudeCodeItemId: String?  // 关联的实体 ID（Provider/MCP/Skill 的唯一标识）

    init(
        id: UUID = UUID(), name: String, path: String, icon: NSImage, isDirectory: Bool,
        displayAlias: String? = nil, isWebLink: Bool = false, isUtility: Bool = false,
        isSystemCommand: Bool = false, isBookmark: Bool = false, bookmarkSource: String? = nil,
        isBookmarkEntry: Bool = false, is2FACode: Bool = false, is2FAEntry: Bool = false,
        isMemeEntry: Bool = false, isFavoriteEntry: Bool = false,
        supportsQueryExtension: Bool = false, defaultUrl: String? = nil,
        isSectionHeader: Bool = false, isReminder: Bool = false,
        reminderIdentifier: String? = nil, reminderColor: NSColor? = nil,
        reminderURL: URL? = nil, processStats: String? = nil,
        isClaudeCodeEntry: Bool = false, isCodexEntry: Bool = false, isClaudeCodeItem: Bool = false,
        claudeCodeItemType: ClaudeCodeItemType? = nil, claudeCodeItemId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
        self.isDirectory = isDirectory
        self.displayAlias = displayAlias
        self.isWebLink = isWebLink
        self.isUtility = isUtility
        self.isSystemCommand = isSystemCommand
        self.isBookmark = isBookmark
        self.bookmarkSource = bookmarkSource
        self.isBookmarkEntry = isBookmarkEntry
        self.is2FACode = is2FACode
        self.is2FAEntry = is2FAEntry
        self.isMemeEntry = isMemeEntry
        self.isFavoriteEntry = isFavoriteEntry
        self.supportsQueryExtension = supportsQueryExtension
        self.defaultUrl = defaultUrl
        self.isSectionHeader = isSectionHeader
        self.isReminder = isReminder
        self.reminderIdentifier = reminderIdentifier
        self.reminderColor = reminderColor
        self.reminderURL = reminderURL
        self.processStats = processStats
        self.isClaudeCodeEntry = isClaudeCodeEntry
        self.isCodexEntry = isCodexEntry
        self.isClaudeCodeItem = isClaudeCodeItem
        self.claudeCodeItemType = claudeCodeItemType
        self.claudeCodeItemId = claudeCodeItemId
    }

    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Claude Code Item Type

enum ClaudeCodeItemType: String, Codable {
    case provider
    case contextPrompt
    case mcp
    case skill
}

extension SearchResult {
    static func fromReminder(_ item: ReminderItem) -> SearchResult {
        // Priority icons: !!! for high, !! for medium, ! for low
        var prefix = ""
        if item.priority == 1 {
            prefix = "!!! "
        } else if item.priority == 5 {
            prefix = "!! "
        } else if item.priority == 9 {
            prefix = "! "
        }

        var subtitle = item.listTitle
        if let date = item.dueDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/M/d, HH:mm"
            subtitle += " • \(formatter.string(from: date))"
        }

        let iconName = item.isCompleted ? "checkmark.circle.fill" : "circle"
        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) ?? NSImage()

        // Store the reminder identifier and URL
        return SearchResult(
            name: prefix + item.title,
            path: item.notes ?? "",
            icon: icon,
            isDirectory: false,
            isReminder: true,
            reminderIdentifier: item.id,
            reminderColor: item.listColor,
            reminderURL: item.url,
            processStats: subtitle
        )
    }
}
