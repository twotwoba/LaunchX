import AppKit
import Foundation

/// IDE 最近项目服务
/// 负责从各 IDE 获取最近打开的项目列表
final class IDERecentProjectsService {
    static let shared = IDERecentProjectsService()

    private init() {}

    // MARK: - Installed IDE Detection

    /// 可用于打开文件夹的应用信息
    struct FolderOpenerApp {
        let name: String
        let path: String
        let icon: NSImage
        let ideType: IDEType?  // nil 表示 Finder 等非 IDE 应用
    }

    /// 获取可用于打开文件夹的应用列表
    /// - Returns: 应用列表，Finder 在最前，然后是已安装的 IDE
    func getAvailableFolderOpeners() -> [FolderOpenerApp] {
        var openers: [FolderOpenerApp] = []

        // 1. Finder 始终在第一位
        let finderPath = "/System/Library/CoreServices/Finder.app"
        if FileManager.default.fileExists(atPath: finderPath) {
            let icon = NSWorkspace.shared.icon(forFile: finderPath)
            icon.size = NSSize(width: 32, height: 32)
            openers.append(
                FolderOpenerApp(name: "Finder", path: finderPath, icon: icon, ideType: nil))
        }

        // 2. 检测已安装的 IDE
        let ideApps: [(IDEType, [String])] = [
            (.vscode, ["/Applications/Visual Studio Code.app"]),
            (.zed, ["/Applications/Zed.app"]),
            (
                .jetbrainsIntelliJ,
                ["/Applications/IntelliJ IDEA.app", "/Applications/IntelliJ IDEA CE.app"]
            ),
            (.jetbrainsPyCharm, ["/Applications/PyCharm.app", "/Applications/PyCharm CE.app"]),
            (.jetbrainsWebStorm, ["/Applications/WebStorm.app"]),
            (.jetbrainsGoLand, ["/Applications/GoLand.app"]),
            (.jetbrainsRider, ["/Applications/Rider.app"]),
            (.jetbrainsClion, ["/Applications/CLion.app"]),
        ]

        for (ideType, possiblePaths) in ideApps {
            for path in possiblePaths {
                if FileManager.default.fileExists(atPath: path) {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    icon.size = NSSize(width: 32, height: 32)
                    let name = FileManager.default.displayName(atPath: path)
                        .replacingOccurrences(of: ".app", with: "")
                    openers.append(
                        FolderOpenerApp(name: name, path: path, icon: icon, ideType: ideType))
                    break  // 每种 IDE 只取第一个找到的
                }
            }
        }

        return openers
    }

    /// 使用指定应用打开文件夹
    /// - Parameters:
    ///   - folderPath: 文件夹路径
    ///   - appPath: 应用路径
    func openFolder(_ folderPath: String, withApp appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath, folderPath]

        do {
            try process.run()
        } catch {
            print("Failed to open folder: \(error)")
        }
    }

    /// 获取指定 IDE 的最近项目
    /// - Parameters:
    ///   - ideType: IDE 类型
    ///   - limit: 最大数量
    /// - Returns: 项目列表
    func getRecentProjects(for ideType: IDEType, limit: Int = 20) -> [IDEProject] {
        switch ideType {
        case .vscode:
            return getVSCodeRecentProjects(limit: limit)
        case .zed:
            return getZedRecentProjects(limit: limit)
        default:
            if ideType.isJetBrains {
                return getJetBrainsRecentProjects(for: ideType, limit: limit)
            }
            return []
        }
    }

    /// 使用指定 IDE 打开项目
    /// - Parameters:
    ///   - project: 项目
    ///   - idePath: IDE 应用路径
    func openProject(_ project: IDEProject, withIDEAt idePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", idePath, project.path]

        do {
            try process.run()
        } catch {
            print("Failed to open project: \(error)")
        }
    }

    // MARK: - VSCode

    private func getVSCodeRecentProjects(limit: Int) -> [IDEProject] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return []
        }

        // 使用 sqlite3 命令行查询
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath, "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8),
                !jsonString.isEmpty
            else {
                return []
            }

            return parseVSCodeRecentProjects(jsonString, limit: limit)
        } catch {
            print("Failed to query VSCode database: \(error)")
            return []
        }
    }

    private func parseVSCodeRecentProjects(_ jsonString: String, limit: Int) -> [IDEProject] {
        guard let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = json["entries"] as? [[String: Any]]
        else {
            return []
        }

        var projects: [IDEProject] = []
        var seenPaths = Set<String>()  // 用于去重

        for entry in entries {
            guard projects.count < limit else { break }

            var path: String?

            // 优先获取 folderUri（项目文件夹）
            if let folderUri = entry["folderUri"] as? String {
                path = uriToPath(folderUri)
            }
            // 其次获取 workspace（工作区文件）
            else if let workspace = entry["workspace"] as? String {
                // 工作区文件，取其所在目录
                if let wsPath = uriToPath(workspace) {
                    path = (wsPath as NSString).deletingLastPathComponent
                }
            }

            guard let projectPath = path,
                !seenPaths.contains(projectPath),
                FileManager.default.fileExists(atPath: projectPath)
            else {
                continue
            }

            seenPaths.insert(projectPath)

            let name = (projectPath as NSString).lastPathComponent
            projects.append(
                IDEProject(
                    name: name,
                    path: projectPath,
                    ideType: .vscode
                ))
        }

        return projects
    }

    // MARK: - Zed

    private func getZedRecentProjects(limit: Int) -> [IDEProject] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zed/db/0-stable/db.sqlite")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return []
        }

        // 使用 sqlite3 命令行查询
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath,
            "SELECT paths, timestamp FROM workspaces WHERE paths IS NOT NULL AND paths != '' ORDER BY timestamp DESC LIMIT \(limit);",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8),
                !output.isEmpty
            else {
                return []
            }

            return parseZedRecentProjects(output, limit: limit)
        } catch {
            print("Failed to query Zed database: \(error)")
            return []
        }
    }

    private func parseZedRecentProjects(_ output: String, limit: Int) -> [IDEProject] {
        var projects: [IDEProject] = []
        var seenPaths = Set<String>()  // 用于去重
        let lines = output.components(separatedBy: "\n")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        for line in lines {
            guard projects.count < limit, !line.isEmpty else { continue }

            // 格式: path|timestamp
            let parts = line.components(separatedBy: "|")
            guard parts.count >= 1 else { continue }

            let path = parts[0]

            // 去重：跳过已经添加过的路径
            guard !seenPaths.contains(path) else { continue }

            guard FileManager.default.fileExists(atPath: path) else { continue }

            seenPaths.insert(path)

            var lastOpened: Date? = nil
            if parts.count >= 2 {
                lastOpened = dateFormatter.date(from: parts[1])
            }

            let name = (path as NSString).lastPathComponent
            projects.append(
                IDEProject(
                    name: name,
                    path: path,
                    lastOpened: lastOpened,
                    ideType: .zed
                ))
        }

        return projects
    }

    // MARK: - JetBrains

    private func getJetBrainsRecentProjects(for ideType: IDEType, limit: Int) -> [IDEProject] {
        // 查找 JetBrains 配置目录
        let appSupportPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JetBrains")
            .path

        guard FileManager.default.fileExists(atPath: appSupportPath) else {
            return []
        }

        // 根据 IDE 类型确定目录前缀
        let dirPrefix: String
        switch ideType {
        case .jetbrainsIntelliJ: dirPrefix = "IntelliJIdea"
        case .jetbrainsPyCharm: dirPrefix = "PyCharm"
        case .jetbrainsWebStorm: dirPrefix = "WebStorm"
        case .jetbrainsGoLand: dirPrefix = "GoLand"
        case .jetbrainsRider: dirPrefix = "Rider"
        case .jetbrainsClion: dirPrefix = "CLion"
        default: return []
        }

        // 查找最新版本的配置目录
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appSupportPath)
        else {
            return []
        }

        let matchingDirs = contents.filter { $0.hasPrefix(dirPrefix) }.sorted().reversed()

        for dir in matchingDirs {
            let recentProjectsPath = (appSupportPath as NSString)
                .appendingPathComponent(dir)
                .appending("/options/recentProjects.xml")

            if FileManager.default.fileExists(atPath: recentProjectsPath) {
                return parseJetBrainsRecentProjects(
                    at: recentProjectsPath, ideType: ideType, limit: limit)
            }
        }

        return []
    }

    private func parseJetBrainsRecentProjects(at path: String, ideType: IDEType, limit: Int)
        -> [IDEProject]
    {
        guard let data = FileManager.default.contents(atPath: path),
            let xml = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var projects: [IDEProject] = []
        var seenPaths = Set<String>()  // 用于去重

        // 简单的 XML 解析，查找 recentPaths 中的路径
        // JetBrains 使用 $USER_HOME$ 作为 home 目录占位符
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // 匹配 <option name="recentPaths"> 或 <entry key="..."> 中的路径
        let pattern = #"<(?:option value|entry key)="([^"]+)"(?:/)?>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        for match in matches {
            guard projects.count < limit,
                let range = Range(match.range(at: 1), in: xml)
            else {
                continue
            }

            var path = String(xml[range])

            // 替换 $USER_HOME$
            path = path.replacingOccurrences(of: "$USER_HOME$", with: homeDir)

            // 去重：跳过已经添加过的路径
            guard !seenPaths.contains(path) else { continue }

            // 跳过非目录路径
            guard FileManager.default.fileExists(atPath: path) else { continue }

            seenPaths.insert(path)

            let name = (path as NSString).lastPathComponent
            projects.append(
                IDEProject(
                    name: name,
                    path: path,
                    ideType: ideType
                ))
        }

        return projects
    }

    // MARK: - Helpers

    /// 将 file:// URI 转换为路径
    private func uriToPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }

        // 移除 file:// 前缀并解码 URL 编码
        let encoded = String(uri.dropFirst(7))
        return encoded.removingPercentEncoding
    }
}
