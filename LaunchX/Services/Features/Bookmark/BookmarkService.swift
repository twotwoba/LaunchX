import AppKit
import Foundation

// MARK: - 书签项目

struct BookmarkItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let url: String
    let source: BookmarkSource
    let folderPath: [String]  // 书签所在的文件夹路径
    let lowerTitle: String  // 预计算小写，搜索时复用，避免每次按键重复 lowercased()
    let lowerUrl: String

    init(title: String, url: String, source: BookmarkSource, folderPath: [String] = []) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.source = source
        self.folderPath = folderPath
        self.lowerTitle = title.lowercased()
        self.lowerUrl = url.lowercased()
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(source)
    }

    static func == (lhs: BookmarkItem, rhs: BookmarkItem) -> Bool {
        lhs.url == rhs.url && lhs.source == rhs.source
    }
}

// MARK: - 书签来源

enum BookmarkSource: String, Codable, CaseIterable {
    case safari = "Safari"
    case chrome = "Chrome"
    case brave = "Brave"
    case arc = "Arc"
    case edge = "Edge"
    case vivaldi = "Vivaldi"
    case opera = "Opera"
    case helium = "Helium"

    var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .arc: return "company.thebrowser.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .opera: return "com.operasoftware.Opera"
        case .helium: return "net.imput.helium"
        }
    }

    var bookmarkPath: String {
        switch self {
        case .safari:
            return NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        case .chrome:
            return NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Default/Bookmarks"
        case .brave:
            return NSHomeDirectory() + "/Library/Application Support/BraveSoftware/Brave-Browser/Default/Bookmarks"
        case .arc:
            return NSHomeDirectory() + "/Library/Application Support/Arc/User Data/Default/Bookmarks"
        case .edge:
            return NSHomeDirectory() + "/Library/Application Support/Microsoft Edge/Default/Bookmarks"
        case .vivaldi:
            return NSHomeDirectory() + "/Library/Application Support/Vivaldi/Default/Bookmarks"
        case .opera:
            return NSHomeDirectory() + "/Library/Application Support/com.operasoftware.Opera/Bookmarks"
        case .helium:
            return NSHomeDirectory() + "/Library/Application Support/net.imput.helium/Default/Bookmarks"
        }
    }

    var isInstalled: Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    var icon: NSImage {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
            appIcon.size = NSSize(width: 16, height: 16)
            return appIcon
        }

        // 如果找不到应用，返回默认图标
        let symbolName: String
        switch self {
        case .safari: symbolName = "safari"
        default: symbolName = "globe"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: displayName) ?? NSImage()
    }

    var displayName: String {
        switch self {
        case .safari: return "Safari 浏览器"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .helium: return "Helium"
        }
    }
}

// MARK: - 书签搜索设置

struct BookmarkSettings: Codable {
    var isEnabled: Bool
    var alias: String  // 别名，如 "bk"
    var openWith: BookmarkOpenWith  // 打开方式
    var enabledSources: [BookmarkSource]  // 启用的浏览器
    var hotKeyCode: UInt32  // 快捷键 keyCode
    var hotKeyModifiers: UInt32  // 快捷键修饰键

    static let `default` = BookmarkSettings(
        isEnabled: true,
        alias: "bk",
        openWith: .defaultBrowser,
        enabledSources: [.safari, .chrome],
        hotKeyCode: 0,
        hotKeyModifiers: 0
    )

    static func load() -> BookmarkSettings {
        if let data = UserDefaults.standard.data(forKey: "bookmarkSettings"),
            var settings = try? JSONDecoder().decode(BookmarkSettings.self, from: data)
        {
            // 验证选中的浏览器是否仍然安装
            if !settings.openWith.isSpecialOption,
               let browserSource = settings.openWith.browserSource,
               !browserSource.isInstalled
            {
                // 浏览器已卸载，回退到默认浏览器
                settings.openWith = .defaultBrowser
                settings.save()  // 保存更新后的设置
            }
            return settings
        }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "bookmarkSettings")
        }
    }
}

// MARK: - 书签打开方式

enum BookmarkOpenWith: String, Codable, CaseIterable {
    case bookmarkBrowser = "bookmarkBrowser"  // 书签所属浏览器
    case defaultBrowser = "defaultBrowser"  // 默认浏览器
    case safari = "safari"
    case chrome = "chrome"
    case brave = "brave"
    case arc = "arc"
    case edge = "edge"
    case vivaldi = "vivaldi"
    case opera = "opera"
    case helium = "helium"

    var displayName: String {
        switch self {
        case .bookmarkBrowser: return "书签浏览器"
        case .defaultBrowser: return "默认浏览器"
        case .safari: return "Safari 浏览器"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .opera: return "Opera"
        case .helium: return "Helium"
        }
    }

    var icon: NSImage {
        switch self {
        case .bookmarkBrowser:
            return NSImage(systemSymbolName: "bookmark", accessibilityDescription: "Bookmark")
                ?? NSImage()
        case .defaultBrowser:
            // 获取默认浏览器图标
            if let defaultBrowser = NSWorkspace.shared.urlForApplication(
                toOpen: URL(string: "https://")!)
            {
                return NSWorkspace.shared.icon(forFile: defaultBrowser.path)
            }
            return NSImage(systemSymbolName: "globe", accessibilityDescription: "Browser")
                ?? NSImage()
        case .safari:
            return BookmarkSource.safari.icon
        case .chrome:
            return BookmarkSource.chrome.icon
        case .brave:
            return BookmarkSource.brave.icon
        case .arc:
            return BookmarkSource.arc.icon
        case .edge:
            return BookmarkSource.edge.icon
        case .vivaldi:
            return BookmarkSource.vivaldi.icon
        case .opera:
            return BookmarkSource.opera.icon
        case .helium:
            return BookmarkSource.helium.icon
        }
    }

    // 获取对应的 BookmarkSource（如果是浏览器选项）
    var browserSource: BookmarkSource? {
        switch self {
        case .safari: return .safari
        case .chrome: return .chrome
        case .brave: return .brave
        case .arc: return .arc
        case .edge: return .edge
        case .vivaldi: return .vivaldi
        case .opera: return .opera
        case .helium: return .helium
        case .bookmarkBrowser, .defaultBrowser: return nil
        }
    }

    // 检查是否是特殊选项
    var isSpecialOption: Bool {
        return self == .bookmarkBrowser || self == .defaultBrowser
    }
}

// MARK: - 书签打开方式选项（UI 层）

enum BookmarkOpenWithOption: Hashable, Identifiable {
    case special(BookmarkOpenWith)  // 特殊选项：书签浏览器、默认浏览器
    case browser(BookmarkSource)    // 具体浏览器

    var id: String {
        switch self {
        case .special(let openWith):
            return openWith.rawValue
        case .browser(let source):
            return source.rawValue
        }
    }

    var displayName: String {
        switch self {
        case .special(let openWith):
            return openWith.displayName
        case .browser(let source):
            return source.displayName
        }
    }

    var icon: NSImage {
        switch self {
        case .special(let openWith):
            return openWith.icon
        case .browser(let source):
            return source.icon
        }
    }

    // 转换为 BookmarkOpenWith 用于存储
    func toBookmarkOpenWith() -> BookmarkOpenWith {
        switch self {
        case .special(let openWith):
            return openWith
        case .browser(let source):
            // 将 BookmarkSource 转换为对应的 BookmarkOpenWith
            switch source {
            case .safari: return .safari
            case .chrome: return .chrome
            case .brave: return .brave
            case .arc: return .arc
            case .edge: return .edge
            case .vivaldi: return .vivaldi
            case .opera: return .opera
            case .helium: return .helium
            }
        }
    }

    // 从 BookmarkOpenWith 创建选项
    static func from(_ openWith: BookmarkOpenWith) -> BookmarkOpenWithOption {
        switch openWith {
        case .bookmarkBrowser, .defaultBrowser:
            return .special(openWith)
        case .safari:
            return .browser(.safari)
        case .chrome:
            return .browser(.chrome)
        case .brave:
            return .browser(.brave)
        case .arc:
            return .browser(.arc)
        case .edge:
            return .browser(.edge)
        case .vivaldi:
            return .browser(.vivaldi)
        case .opera:
            return .browser(.opera)
        case .helium:
            return .browser(.helium)
        }
    }
}

// MARK: - 书签服务

final class BookmarkService {
    static let shared = BookmarkService()

    private var cachedBookmarks: [BookmarkItem] = []
    private var lastLoadTime: Date?
    private let cacheValidDuration: TimeInterval = 60  // 缓存有效期 60 秒
    private let lock = NSLock()  // 保护 cachedBookmarks/lastLoadTime（搜索在后台线程执行）

    private init() {}

    // MARK: - 公开 API

    /// 获取所有书签
    func getAllBookmarks(forceReload: Bool = false) -> [BookmarkItem] {
        // 快速路径：命中缓存则返回快照（值类型拷贝），持锁时间极短
        lock.lock()
        if !forceReload,
            let lastLoad = lastLoadTime,
            Date().timeIntervalSince(lastLoad) < cacheValidDuration,
            !cachedBookmarks.isEmpty
        {
            let snapshot = cachedBookmarks
            lock.unlock()
            return snapshot
        }
        lock.unlock()

        // 慢路径：缓存过期，重载书签（IO 在锁外，避免长时间持锁）
        var bookmarks: [BookmarkItem] = []
        let settings = BookmarkSettings.load()

        for source in settings.enabledSources {
            switch source {
            case .safari:
                bookmarks.append(contentsOf: loadSafariBookmarks())
            case .chrome, .brave, .arc, .edge, .vivaldi, .opera, .helium:
                bookmarks.append(contentsOf: loadChromiumBookmarks(source: source))
            }
        }

        lock.lock()
        cachedBookmarks = bookmarks
        lastLoadTime = Date()
        lock.unlock()
        return bookmarks
    }

    /// 搜索书签
    func search(query: String) -> [BookmarkItem] {
        let bookmarks = getAllBookmarks()
        guard !query.isEmpty else { return bookmarks }

        let queryLower = query.lowercased()
        return bookmarks.filter { bookmark in
            bookmark.lowerTitle.contains(queryLower)
                || bookmark.lowerUrl.contains(queryLower)
        }
    }

    /// 打开书签
    func open(_ bookmark: BookmarkItem) {
        guard let url = URL(string: bookmark.url) else { return }

        let settings = BookmarkSettings.load()

        switch settings.openWith {
        case .bookmarkBrowser:
            openWithBrowser(url: url, source: bookmark.source)
        case .defaultBrowser:
            AppOpener.open(url)
        case .safari:
            openWithBrowser(url: url, source: .safari)
        case .chrome:
            openWithBrowser(url: url, source: .chrome)
        case .brave:
            openWithBrowser(url: url, source: .brave)
        case .arc:
            openWithBrowser(url: url, source: .arc)
        case .edge:
            openWithBrowser(url: url, source: .edge)
        case .vivaldi:
            openWithBrowser(url: url, source: .vivaldi)
        case .opera:
            openWithBrowser(url: url, source: .opera)
        case .helium:
            openWithBrowser(url: url, source: .helium)
        }
    }

    /// 清除缓存
    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedBookmarks = []
        lastLoadTime = nil
    }

    // MARK: - Safari 书签

    private func loadSafariBookmarks() -> [BookmarkItem] {
        let bookmarksPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"

        guard FileManager.default.fileExists(atPath: bookmarksPath),
            let data = FileManager.default.contents(atPath: bookmarksPath),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else {
            print("[BookmarkService] Failed to load Safari bookmarks")
            return []
        }

        var bookmarks: [BookmarkItem] = []
        parseBookmarkFolder(plist, into: &bookmarks, source: .safari, folderPath: [])
        return bookmarks
    }

    private func parseBookmarkFolder(
        _ dict: [String: Any], into bookmarks: inout [BookmarkItem], source: BookmarkSource,
        folderPath: [String]
    ) {
        guard let children = dict["Children"] as? [[String: Any]] else { return }

        for child in children {
            let type = child["WebBookmarkType"] as? String

            if type == "WebBookmarkTypeLeaf" {
                // 这是一个书签
                if let urlDict = child["URLString"] as? String,
                    let title = (child["URIDictionary"] as? [String: Any])?["title"] as? String
                        ?? child["Title"] as? String
                {
                    let bookmark = BookmarkItem(
                        title: title,
                        url: urlDict,
                        source: source,
                        folderPath: folderPath
                    )
                    bookmarks.append(bookmark)
                }
            } else if type == "WebBookmarkTypeList" {
                // 这是一个文件夹，递归处理
                let folderTitle = child["Title"] as? String ?? ""
                var newPath = folderPath
                if !folderTitle.isEmpty && folderTitle != "BookmarksBar"
                    && folderTitle != "BookmarksMenu"
                {
                    newPath.append(folderTitle)
                }
                parseBookmarkFolder(child, into: &bookmarks, source: source, folderPath: newPath)
            }
        }
    }

    // MARK: - Chromium 系浏览器书签

    private func loadChromiumBookmarks(source: BookmarkSource) -> [BookmarkItem] {
        let bookmarksPath = source.bookmarkPath

        guard FileManager.default.fileExists(atPath: bookmarksPath),
            let data = FileManager.default.contents(atPath: bookmarksPath),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let roots = json["roots"] as? [String: Any]
        else {
            print("[BookmarkService] Failed to load \(source.displayName) bookmarks")
            return []
        }

        var bookmarks: [BookmarkItem] = []

        // 解析书签栏
        if let bookmarkBar = roots["bookmark_bar"] as? [String: Any] {
            parseChromiumBookmarkFolder(bookmarkBar, into: &bookmarks, source: source, folderPath: [])
        }

        // 解析其他书签
        if let other = roots["other"] as? [String: Any] {
            parseChromiumBookmarkFolder(other, into: &bookmarks, source: source, folderPath: [])
        }

        return bookmarks
    }

    private func parseChromiumBookmarkFolder(
        _ dict: [String: Any], into bookmarks: inout [BookmarkItem], source: BookmarkSource, folderPath: [String]
    ) {
        guard let children = dict["children"] as? [[String: Any]] else { return }

        for child in children {
            let type = child["type"] as? String

            if type == "url" {
                // 这是一个书签
                if let url = child["url"] as? String,
                    let name = child["name"] as? String
                {
                    let bookmark = BookmarkItem(
                        title: name,
                        url: url,
                        source: source,
                        folderPath: folderPath
                    )
                    bookmarks.append(bookmark)
                }
            } else if type == "folder" {
                // 这是一个文件夹，递归处理
                let folderName = child["name"] as? String ?? ""
                var newPath = folderPath
                if !folderName.isEmpty {
                    newPath.append(folderName)
                }
                parseChromiumBookmarkFolder(child, into: &bookmarks, source: source, folderPath: newPath)
            }
        }
    }

    // MARK: - 辅助方法

    private func openWithBrowser(url: URL, source: BookmarkSource) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) {
            AppOpener.open([url], withApplicationAt: appURL)
        } else {
            // 如果浏览器未安装，使用默认浏览器打开
            AppOpener.open(url)
        }
    }

    /// 检查是否有完全磁盘访问权限（Safari 书签需要）
    func checkFullDiskAccess() -> Bool {
        let testPath = NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"
        return FileManager.default.isReadableFile(atPath: testPath)
    }
}
