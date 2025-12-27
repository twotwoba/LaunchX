import AppKit
import Foundation

/// 工具配置管理
struct ToolsConfig: Codable {
    /// 工具列表
    var tools: [ToolItem] = []

    // MARK: - 便捷访问

    /// 应用工具
    var appTools: [ToolItem] {
        tools.filter { $0.type == .app }
    }

    /// 网页直达工具
    var webLinkTools: [ToolItem] {
        tools.filter { $0.type == .webLink }
    }

    /// 实用工具
    var utilityTools: [ToolItem] {
        tools.filter { $0.type == .utility }
    }

    /// 系统命令工具
    var systemCommandTools: [ToolItem] {
        tools.filter { $0.type == .systemCommand }
    }

    /// 已启用的工具
    var enabledTools: [ToolItem] {
        tools.filter { $0.isEnabled }
    }

    // MARK: - 持久化

    private static let configKey = "ToolsConfig"
    private static let migrationKey = "ToolsConfigMigrated"
    private static let defaultWebLinksAddedKey = "DefaultWebLinksAdded"

    /// 从 UserDefaults 加载配置（含自动迁移）
    static func load() -> ToolsConfig {
        // 1. 尝试加载新格式
        if let data = UserDefaults.standard.data(forKey: configKey),
            var config = try? JSONDecoder().decode(ToolsConfig.self, from: data)
        {
            // 检查是否需要添加默认网页直达
            if !UserDefaults.standard.bool(forKey: defaultWebLinksAddedKey) {
                config.addDefaultWebLinksIfNeeded()
                // 先设置标记，避免循环
                UserDefaults.standard.set(true, forKey: defaultWebLinksAddedKey)
                config.save()
            }
            return config
        }

        // 2. 尝试迁移旧格式
        if !UserDefaults.standard.bool(forKey: migrationKey),
            let migrated = migrateFromCustomItemsConfig()
        {
            var config = migrated
            // 迁移后也添加默认网页直达
            config.addDefaultWebLinksIfNeeded()
            // 先设置标记，避免循环
            UserDefaults.standard.set(true, forKey: migrationKey)
            UserDefaults.standard.set(true, forKey: defaultWebLinksAddedKey)
            config.save()
            return config
        }

        // 3. 返回带有默认网页直达的配置
        var config = ToolsConfig()
        config.tools = defaultWebLinks()
        // 先设置标记，避免循环
        UserDefaults.standard.set(true, forKey: defaultWebLinksAddedKey)
        config.save()
        return config
    }

    /// 添加默认网页直达（如果尚未添加）
    private mutating func addDefaultWebLinksIfNeeded() {
        let defaults = ToolsConfig.defaultWebLinks()
        let existingUrls = Set(tools.compactMap { $0.url })

        for webLink in defaults {
            // 只添加 URL 不存在的
            if let url = webLink.url, !existingUrls.contains(url) {
                tools.append(webLink)
            }
        }
    }

    /// 从 Asset Catalog 加载图标数据
    private static func loadIconData(named name: String) -> Data? {
        guard let image = NSImage(named: name) else { return nil }
        guard let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return pngData
    }

    /// 默认网页直达列表
    private static func defaultWebLinks() -> [ToolItem] {
        return [
            ToolItem.webLink(
                name: "Google",
                url: "https://www.google.com/search?q={query}",
                alias: "go",
                iconData: loadIconData(named: "WebLink_google"),
                showInSearchPanel: true
            ),
            ToolItem.webLink(
                name: "GitHub",
                url: "https://www.github.com/search?q={query}",
                alias: "gh",
                iconData: loadIconData(named: "WebLink_github"),
                showInSearchPanel: true
            ),
            ToolItem.webLink(
                name: "DeepSeek",
                url: "https://chat.deepseek.com/",
                alias: "deep",
                iconData: loadIconData(named: "WebLink_deepseek"),
                showInSearchPanel: false
            ),
            ToolItem.webLink(
                name: "哔哩哔哩",
                url: "https://search.bilibili.com/all?keyword={query}",
                alias: "bl",
                iconData: loadIconData(named: "WebLink_bilibili"),
                showInSearchPanel: true
            ),
            ToolItem.webLink(
                name: "YouTube",
                url: "https://www.youtube.com/results?search_query={query}",
                alias: "yt",
                iconData: loadIconData(named: "WebLink_youtube"),
                showInSearchPanel: true
            ),
            ToolItem.webLink(
                name: "Twitter",
                url: "https://twitter.com/search?q={query}",
                alias: "tt",
                iconData: loadIconData(named: "WebLink_twitter"),
                showInSearchPanel: false
            ),
            ToolItem.webLink(
                name: "微博",
                url: "https://s.weibo.com/weibo/{query}",
                alias: "wb",
                iconData: loadIconData(named: "WebLink_weibo"),
                showInSearchPanel: false
            ),
            ToolItem.webLink(
                name: "V2EX",
                url: "https://www.v2ex.com/?q={query}",
                alias: "v2",
                iconData: loadIconData(named: "WebLink_v2ex"),
                showInSearchPanel: false
            ),
            ToolItem.webLink(
                name: "天眼查",
                url: "https://www.tianyancha.com/search?key={query}",
                alias: "tyc",
                iconData: loadIconData(named: "WebLink_tianyancha"),
                showInSearchPanel: false
            ),
        ]
    }

    /// 保存配置到 UserDefaults
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: ToolsConfig.configKey)
            // 发送配置变化通知
            NotificationCenter.default.post(name: .toolsConfigDidChange, object: nil)
            // 过渡期：同时发送旧通知以保持兼容
            NotificationCenter.default.post(name: .customItemsConfigDidChange, object: nil)
        }
    }

    /// 重置配置
    static func reset() {
        UserDefaults.standard.removeObject(forKey: configKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        NotificationCenter.default.post(name: .toolsConfigDidChange, object: nil)
    }

    // MARK: - 迁移逻辑

    /// 从 CustomItemsConfig 迁移
    private static func migrateFromCustomItemsConfig() -> ToolsConfig? {
        let oldConfig = CustomItemsConfig.load()
        guard !oldConfig.customItems.isEmpty else { return nil }

        var newConfig = ToolsConfig()
        for item in oldConfig.customItems {
            newConfig.tools.append(ToolItem.fromCustomItem(item))
        }
        return newConfig
    }

    // MARK: - 别名映射

    /// 获取别名映射表（alias -> path/url）
    /// 用于 MemoryIndex 的别名搜索
    func aliasMap() -> [String: String] {
        var map: [String: String] = [:]
        for tool in enabledTools {
            guard let alias = tool.alias, !alias.isEmpty else { continue }

            switch tool.type {
            case .app:
                if let path = tool.path {
                    map[alias.lowercased()] = path
                }
            case .webLink:
                if let url = tool.url {
                    map[alias.lowercased()] = url
                }
            case .utility:
                if let identifier = tool.extensionIdentifier {
                    map[alias.lowercased()] = identifier
                }
            case .systemCommand:
                if let command = tool.command {
                    map[alias.lowercased()] = command
                }
            }
        }
        return map
    }

    // MARK: - 快捷键管理

    /// 获取所有已配置的快捷键
    /// - Returns: 元组数组 (快捷键配置, 工具ID, 是否为进入扩展快捷键)
    func allHotKeys() -> [(config: HotKeyConfig, toolId: UUID, isExtension: Bool)] {
        var hotKeys: [(HotKeyConfig, UUID, Bool)] = []
        for tool in enabledTools {
            if let hotKey = tool.hotKey {
                hotKeys.append((hotKey, tool.id, false))
            }
            if tool.isIDE, let extKey = tool.extensionHotKey {
                hotKeys.append((extKey, tool.id, true))
            }
        }
        return hotKeys
    }

    /// 检查快捷键是否已被使用
    /// - Parameters:
    ///   - keyCode: 按键代码
    ///   - modifiers: 修饰键
    ///   - excludingToolId: 排除的工具 ID（用于编辑时排除自身）
    ///   - excludingIsExtension: 排除的快捷键类型
    /// - Returns: 冲突的工具名称，nil 表示无冲突
    func checkHotKeyConflict(
        keyCode: UInt32,
        modifiers: UInt32,
        excludingToolId: UUID? = nil,
        excludingIsExtension: Bool? = nil
    ) -> String? {
        for tool in tools {
            // 检查主快捷键
            if let hotKey = tool.hotKey,
                hotKey.keyCode == keyCode && hotKey.modifiers == modifiers
            {
                // 如果是同一工具的同类型快捷键，跳过
                if let excludeId = excludingToolId,
                    let excludeIsExt = excludingIsExtension,
                    tool.id == excludeId && !excludeIsExt
                {
                    continue
                }
                return "\(tool.name) (打开)"
            }

            // 检查扩展快捷键
            if let extKey = tool.extensionHotKey,
                extKey.keyCode == keyCode && extKey.modifiers == modifiers
            {
                // 如果是同一工具的同类型快捷键，跳过
                if let excludeId = excludingToolId,
                    let excludeIsExt = excludingIsExtension,
                    tool.id == excludeId && excludeIsExt
                {
                    continue
                }
                return "\(tool.name) (进入扩展)"
            }
        }
        return nil
    }

    // MARK: - 查找方法

    /// 根据 ID 查找工具
    func tool(byId id: UUID) -> ToolItem? {
        tools.first { $0.id == id }
    }

    /// 根据路径查找工具（仅 App 类型）
    func tool(byPath path: String) -> ToolItem? {
        tools.first { $0.type == .app && $0.path == path }
    }

    /// 根据 URL 查找工具（仅 WebLink 类型）
    func tool(byURL url: String) -> ToolItem? {
        tools.first { $0.type == .webLink && $0.url == url }
    }

    /// 根据别名查找工具
    func tool(byAlias alias: String) -> ToolItem? {
        let lowercased = alias.lowercased()
        return tools.first { $0.alias?.lowercased() == lowercased }
    }

    // MARK: - 增删改

    /// 添加工具
    mutating func addTool(_ tool: ToolItem) {
        // 检查是否已存在相同的工具
        switch tool.type {
        case .app:
            guard !tools.contains(where: { $0.type == .app && $0.path == tool.path }) else {
                return
            }
        case .webLink:
            guard !tools.contains(where: { $0.type == .webLink && $0.url == tool.url }) else {
                return
            }
        case .utility:
            guard
                !tools.contains(where: {
                    $0.type == .utility && $0.extensionIdentifier == tool.extensionIdentifier
                })
            else { return }
        case .systemCommand:
            guard
                !tools.contains(where: { $0.type == .systemCommand && $0.command == tool.command })
            else { return }
        }
        tools.append(tool)
    }

    /// 更新工具
    mutating func updateTool(_ tool: ToolItem) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
        }
    }

    /// 删除工具
    mutating func removeTool(byId id: UUID) {
        tools.removeAll { $0.id == id }
    }

    /// 删除多个工具
    mutating func removeTools(at offsets: IndexSet) {
        let indicesToRemove = offsets.sorted(by: >)
        for index in indicesToRemove {
            tools.remove(at: index)
        }
    }

    /// 切换工具启用状态
    mutating func toggleEnabled(toolId: UUID) {
        if let index = tools.firstIndex(where: { $0.id == toolId }) {
            tools[index].isEnabled.toggle()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// 工具配置变化通知
    static let toolsConfigDidChange = Notification.Name("toolsConfigDidChange")
}
