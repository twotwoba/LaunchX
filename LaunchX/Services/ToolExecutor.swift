import AppKit
import Foundation

/// 工具执行服务
/// 负责执行不同类型的工具（打开应用、打开网页、执行命令等）
class ToolExecutor {
    static let shared = ToolExecutor()

    private init() {}

    // MARK: - 执行工具

    /// 执行工具
    /// - Parameters:
    ///   - tool: 要执行的工具
    ///   - isExtension: 是否为扩展模式（仅 IDE 应用有效）
    func execute(_ tool: ToolItem, isExtension: Bool = false) {
        guard tool.isEnabled else {
            print("[ToolExecutor] Tool '\(tool.name)' is disabled, skipping execution")
            return
        }

        // 记录 LRU 使用（扩展模式不记录，因为用户只是进入了选择界面）
        if !isExtension {
            recordLRUUsage(tool)
        }

        switch tool.type {
        case .app:
            executeApp(tool, isExtension: isExtension)

        case .webLink:
            executeWebLink(tool, isExtension: isExtension)

        case .utility:
            executeUtility(tool)

        case .systemCommand:
            executeSystemCommand(tool)
        }
    }

    /// 记录工具使用到 LRU 缓存
    private func recordLRUUsage(_ tool: ToolItem) {
        switch tool.type {
        case .app:
            if let path = tool.path {
                RecentAppsManager.shared.recordAppOpen(path: path)
            }
        case .webLink:
            if let url = tool.url {
                RecentAppsManager.shared.recordWebLinkOpen(url: url, name: tool.name)
            }
        case .utility:
            if let identifier = tool.extensionIdentifier {
                RecentAppsManager.shared.recordUtilityOpen(identifier: identifier, name: tool.name)
            }
        case .systemCommand:
            if let command = tool.command {
                RecentAppsManager.shared.recordSystemCommandOpen(command: command, name: tool.name)
            }
        }
    }

    // MARK: - 应用执行

    private func executeApp(_ tool: ToolItem, isExtension: Bool) {
        guard let path = tool.path else {
            print("[ToolExecutor] App tool '\(tool.name)' has no path")
            return
        }

        if isExtension, let ideType = tool.ideType {
            // 进入 IDE 项目模式
            print("[ToolExecutor] Opening IDE mode for '\(tool.name)'")
            PanelManager.shared.showPanelInIDEMode(idePath: path, ideType: ideType)
        } else {
            // 直接打开应用或文件夹
            print("[ToolExecutor] Opening app/folder: \(path)")
            let url = URL(fileURLWithPath: path)
            AppOpener.open(url)
        }
    }

    // MARK: - 网页直达执行

    private func executeWebLink(_ tool: ToolItem, isExtension: Bool) {
        guard let urlString = tool.url else {
            print("[ToolExecutor] WebLink tool '\(tool.name)' has no URL")
            return
        }

        // 如果是扩展模式且支持 query，进入搜索面板的 query 输入模式
        if isExtension && tool.supportsQueryExtension {
            print("[ToolExecutor] Opening WebLink query mode for '\(tool.name)'")
            PanelManager.shared.showPanelInWebLinkQueryMode(tool: tool)
            return
        }

        // 确保 URL 有协议前缀
        var normalizedURL = urlString
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }

        // 处理 {query} 占位符
        var finalUrl = normalizedURL
        if tool.supportsQueryExtension {
            // 如果 URL 包含 {query}，通过快捷键直接打开时：
            // 1. 优先使用默认 URL
            // 2. 否则去掉 {query} 占位符
            if let defaultUrl = tool.defaultUrl, !defaultUrl.isEmpty {
                finalUrl = defaultUrl
                // 确保默认 URL 也有协议前缀
                if !finalUrl.hasPrefix("http://") && !finalUrl.hasPrefix("https://") {
                    finalUrl = "https://" + finalUrl
                }
            } else {
                finalUrl = normalizedURL.replacingOccurrences(of: "{query}", with: "")
            }
        }

        guard let url = URL(string: finalUrl) else {
            print("[ToolExecutor] Invalid URL: \(finalUrl)")
            return
        }

        print("[ToolExecutor] Opening URL: \(url)")
        AppOpener.open(url)
    }

    // MARK: - 实用工具执行

    private func executeUtility(_ tool: ToolItem) {
        guard let identifier = tool.extensionIdentifier else {
            print("[ToolExecutor] Utility tool '\(tool.name)' has no extension identifier")
            return
        }

        print("[ToolExecutor] Executing utility: \(identifier)")
        // 进入实用工具扩展模式
        PanelManager.shared.showPanelInUtilityMode(tool: tool)
    }

    // MARK: - 系统命令执行

    private func executeSystemCommand(_ tool: ToolItem) {
        guard let command = tool.command else {
            print("[ToolExecutor] SystemCommand tool '\(tool.name)' has no command")
            return
        }

        print("[ToolExecutor] Executing system command: \(command)")

        // 先隐藏面板，避免弹窗被遮挡
        PanelManager.shared.hidePanel()

        // 执行系统命令
        SystemCommandService.shared.execute(identifier: command) { success in
            if success {
                print("[ToolExecutor] System command '\(command)' executed successfully")
            } else {
                print("[ToolExecutor] System command '\(command)' failed or was cancelled")
            }
        }
    }

    // MARK: - 便捷方法

    /// 通过工具 ID 执行
    func execute(toolId: UUID, isExtension: Bool = false) {
        let config = ToolsConfig.load()
        guard let tool = config.tool(byId: toolId) else {
            print("[ToolExecutor] Tool not found: \(toolId)")
            return
        }
        execute(tool, isExtension: isExtension)
    }

    /// 通过别名执行
    func execute(alias: String) {
        let config = ToolsConfig.load()
        guard let tool = config.tool(byAlias: alias) else {
            print("[ToolExecutor] Tool not found for alias: \(alias)")
            return
        }
        execute(tool)
    }
}
