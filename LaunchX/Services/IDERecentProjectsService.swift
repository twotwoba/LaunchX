import AppKit
import Foundation

/// IDE 最近项目服务
/// 负责从各 IDE 获取最近打开的项目列表
final class IDERecentProjectsService {
    static let shared = IDERecentProjectsService()

    private init() {}

    // 缓存 getFolderOpeners 结果，避免频繁检测 IDE 安装状态
    private var cachedFolderOpeners: [FolderOpenerApp]?
    private var folderOpenersCacheTimestamp: Date = .distantPast
    private let folderOpenersCacheDuration: TimeInterval = 30  // 30 秒缓存

    enum CommandError: Error {
        case invalidUTF8
        case nonZeroExitStatus(Int32)
    }

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
    /// - Note: 结果缓存 30 秒，避免频繁检测 IDE 安装状态
    func getAvailableFolderOpeners() -> [FolderOpenerApp] {
        // 使用缓存避免频繁遍历 IDE 类型
        if let cached = cachedFolderOpeners,
            Date().timeIntervalSince(folderOpenersCacheTimestamp) < folderOpenersCacheDuration
        {
            return cached
        }

        let openers = buildFolderOpenersList()
        cachedFolderOpeners = openers
        folderOpenersCacheTimestamp = Date()
        return openers
    }

    /// 清除缓存（在 IDE 安装/卸载后调用）
    func invalidateFolderOpenersCache() {
        cachedFolderOpeners = nil
    }

    /// 实际构建可用打开器列表（不缓存）
    private func buildFolderOpenersList() -> [FolderOpenerApp] {
        var openers: [FolderOpenerApp] = []

        // 1. Finder 始终在第一位
        let finderPath = "/System/Library/CoreServices/Finder.app"
        if FileManager.default.fileExists(atPath: finderPath) {
            let icon = NSWorkspace.shared.icon(forFile: finderPath)
            icon.size = NSSize(width: 32, height: 32)
            openers.append(
                FolderOpenerApp(name: "Finder", path: finderPath, icon: icon, ideType: nil))
        }

        // 2. 检测已安装的 IDE (通过 Bundle ID)
        for ideType in IDEType.allCases {
            for bundleId in ideType.bundleIdentifiers {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                {
                    let path = appURL.path
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    icon.size = NSSize(width: 32, height: 32)
                    let name = FileManager.default.displayName(atPath: path)
                        .replacingOccurrences(of: ".app", with: "")

                    openers.append(
                        FolderOpenerApp(name: name, path: path, icon: icon, ideType: ideType))
                    break  // 每种 IDE 类型只添加一个（如已安装多个版本，取检测到的第一个）
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
        launch(targetPath: folderPath, withAppAt: appPath, isJetBrains: isJetBrainsApp(appPath))
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
        case .cursor:
            return getCursorRecentProjects(limit: limit)
        case .zed:
            return getZedRecentProjects(limit: limit)
        case .antigravity:
            return getAntigravityRecentProjects(limit: limit)
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
        launch(targetPath: project.path, withAppAt: idePath, isJetBrains: project.ideType.isJetBrains)
    }

    /// 判断指定应用路径是否为 JetBrains 系列 IDE（用于决定打开方式）
    private func isJetBrainsApp(_ appPath: String) -> Bool {
        IDEType.detect(from: appPath)?.isJetBrains == true
    }

    /// 指定应用是否已在运行（JetBrains 冷/热启动分流依据；runningApplications 须在主线程访问）
    private func isAppRunning(_ appPath: String) -> Bool {
        guard let bundleId = Bundle(path: appPath)?.bundleIdentifier else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// 启动应用并打开目标路径（项目文件夹或普通文件夹）。
    ///
    /// JetBrains 系列按「冷/热启动」分流：
    /// - **热启动（IDE 已在运行）**：必须走 IDE 自带的启动器二进制 `Contents/MacOS/<exec>`，而非 `open -a`。
    ///   `open -a <app> <path>` 走 macOS LaunchServices 的「打开文档」Apple Event，当目标项目已打开
    ///   （尤其在全屏 Space 中）时，JetBrains 会新建一个空白窗口、且无法切到已有的全屏面板；
    ///   改用启动器二进制后，它通过 IPC 把「打开/激活项目」转发给已运行实例，由实例自身激活对应窗口，
    ///   能正确跨 Space（含全屏）切换，且非全屏时也不再闪烁。
    /// - **冷启动（IDE 未运行）**：不存在上述窗口复用问题，走 `open -a`。若用 `Process` 直接启动二进制，
    ///   IDE 会终身作为 LaunchX 的子进程存活，活动监视器会把 IDE（JVM/索引/AI 子进程）数小时的能耗
    ///   全部归因到 LaunchX 头上；`open -a` 由 launchd 拉起，归因独立。热启动路径的启动器二进制在 IPC
    ///   转发后立即退出，不会形成长驻子进程，无此顾虑。
    ///
    /// 其余应用（VSCode/Cursor/Finder 等）始终沿用 `open -a`，其窗口复用机制不受此问题影响。
    private func launch(targetPath: String, withAppAt appPath: String, isJetBrains: Bool) {
        if isJetBrains,
           let launcherURL = Bundle(path: appPath)?.executableURL,
           isAppRunning(appPath)
        {
            let process = Process()
            process.executableURL = launcherURL
            process.arguments = [targetPath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                return
            } catch {
                print(
                    "Failed to open via JetBrains launcher (\(launcherURL.path)): \(error) — fallback to open -a"
                )
            }
        }

        // 冷启动 / 兜底 / 非 JetBrains：沿用 open -a
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appPath, targetPath]
        do {
            try process.run()
        } catch {
            print("Failed to open \(targetPath) with \(appPath): \(error)")
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

        do {
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath, "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';",
                ])
            guard !jsonString.isEmpty else { return [] }

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

    // MARK: - Cursor

    private func getCursorRecentProjects(limit: Int) -> [IDEProject] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return []
        }

        do {
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath, "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';",
                ])
            guard !jsonString.isEmpty else { return [] }

            return parseCursorRecentProjects(jsonString, limit: limit)
        } catch {
            print("Failed to query Cursor database: \(error)")
            return []
        }
    }

    private func parseCursorRecentProjects(_ jsonString: String, limit: Int) -> [IDEProject] {
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
                    ideType: .cursor
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

        do {
            let output = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath,
                    "SELECT paths, timestamp FROM workspaces WHERE paths IS NOT NULL AND paths != '' ORDER BY timestamp DESC LIMIT \(limit);",
                ])
            guard !output.isEmpty else { return [] }

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
            let configDir = (appSupportPath as NSString).appendingPathComponent(dir)
            let recentProjectsPath = (configDir as NSString)
                .appendingPathComponent("options/recentProjects.xml")

            guard FileManager.default.fileExists(atPath: recentProjectsPath) else { continue }

            // JetBrains 2024+ 不会及时把新打开的项目写回 options/recentProjects.xml（该文件仅在
            // 设置落盘、如重启时才更新），但每次打开/关闭都会刷新 workspace/<id>.xml。因此直接读
            // recentProjects.xml 会漏掉新项目且时间滞后。这里以其为基准（提供规范路径、workspaceId
            // 映射与 activationTimestamp），叠加 workspace/ 目录扫描（提供最新打开时间，并补出
            // recentProjects.xml 尚未收录的新项目）。
            let workspaceDir = (configDir as NSString).appendingPathComponent("workspace")
            return parseJetBrainsRecentProjectsMerged(
                recentProjectsPath: recentProjectsPath,
                workspaceDir: workspaceDir,
                ideType: ideType,
                limit: limit)
        }

        return []
    }

    /// 合并 recentProjects.xml 与 workspace/ 目录扫描，得到最新的"最近打开"项目列表。
    ///
    /// 背景：JetBrains 2024+ 把每次打开/关闭的项目状态实时写入 `workspace/<id>.xml`，
    /// 但 `options/recentProjects.xml` 仅在设置落盘（如重启）时才更新。只读 recentProjects.xml
    /// 会漏掉新打开的项目，且 activationTimestamp 滞后。这里以两份数据合并：
    /// - recentProjects.xml 提供规范路径、workspaceId→path 映射与 activationTimestamp（可能滞后）；
    /// - workspace/ 提供每个项目最新的修改时间（≈ 最近打开时间），并能补出 recentProjects.xml
    ///   尚未收录的新项目。
    /// 同名项目取两者中更新的时间；仅保留磁盘上仍然存在的路径。
    func parseJetBrainsRecentProjectsMerged(
        recentProjectsPath: String,
        workspaceDir: String,
        ideType: IDEType,
        limit: Int
    ) -> [IDEProject] {
        // 1) recentProjects.xml：path -> 最近打开时间；workspaceId -> path（用于兜底反查）
        var pathToLastOpened: [String: Date] = [:]
        var idToPath: [String: String] = [:]
        if let data = FileManager.default.contents(atPath: recentProjectsPath),
            let xml = String(data: data, encoding: .utf8)
        {
            for entry in Self.parseJetBrainsEntries(xml) {
                pathToLastOpened[entry.path] = entry.lastOpened
                if let id = entry.workspaceId {
                    idToPath[id] = entry.path
                }
            }
        }

        // 2) workspace/ 目录：path -> 最新修改时间（合并同一项目的多个文件）
        var workspaceLastOpened: [String: Date] = [:]
        for ws in scanJetBrainsWorkspaceDir(workspaceDir) {
            // 优先用 workspace 文件内解析出的绝对路径；解析不到（仅含 $PROJECT_DIR$ 宏）时，
            // 退回用文件名（即 workspaceId）在 recentProjects.xml 中反查路径。
            guard let path = ws.path ?? idToPath[ws.workspaceId] else { continue }
            if let prev = workspaceLastOpened[path] {
                workspaceLastOpened[path] = max(prev, ws.modified)
            } else {
                workspaceLastOpened[path] = ws.modified
            }
        }

        // 3) 合并：以 path 为键，仅保留磁盘上存在的路径，时间取两者更新的那个
        var merged: [String: Date] = [:]
        for (path, ts) in pathToLastOpened
            where FileManager.default.fileExists(atPath: path)
        {
            merged[path] = ts
        }
        for (path, mtime) in workspaceLastOpened
            where FileManager.default.fileExists(atPath: path)
        {
            merged[path] = max(merged[path] ?? .distantPast, mtime)
        }

        // 4) 构造结果，按最近打开时间降序，无时间的排最后
        var projects = merged.map { path, lastOpened in
            IDEProject(
                name: (path as NSString).lastPathComponent,
                path: path,
                lastOpened: lastOpened,
                ideType: ideType)
        }
        projects.sort { lhs, rhs in
            switch (lhs.lastOpened, rhs.lastOpened) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return false
            }
        }
        return projects.count > limit ? Array(projects.prefix(limit)) : projects
    }

    /// 扫描 workspace/ 目录，返回每个 `<workspaceId>.xml` 的 (workspaceId, 解析到的绝对路径?, 修改时间)。
    /// 路径解析失败（文件内仅含 $PROJECT_DIR$ 宏）时 path 为 nil，调用方可通过 workspaceId
    /// 在 recentProjects.xml 中反查。
    private func scanJetBrainsWorkspaceDir(_ workspaceDir: String)
        -> [(workspaceId: String, path: String?, modified: Date)]
    {
        guard let fileNames = try? FileManager.default.contentsOfDirectory(atPath: workspaceDir)
        else {
            return []
        }
        let fm = FileManager.default
        var results: [(workspaceId: String, path: String?, modified: Date)] = []
        for fileName in fileNames where fileName.hasSuffix(".xml") {
            let workspaceId = String(fileName.dropLast(".xml".count))
            let fullPath = (workspaceDir as NSString).appendingPathComponent(fileName)
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                let modified = attrs[.modificationDate] as? Date
            else {
                continue
            }
            results.append(
                (
                    workspaceId: workspaceId,
                    path: Self.extractJetBrainsWorkspacePath(at: fullPath),
                    modified: modified
                ))
        }
        return results
    }

    /// 从 workspace XML 中提取项目绝对路径。
    /// IDEA 在项目结构节点里记录形如 `file:///Users/.../project` 的 URL；取其中最浅（最短）的一条
    /// 作为项目根目录。仅含 `$PROJECT_DIR$` 宏（无绝对路径）时返回 nil。
    static func extractJetBrainsWorkspacePath(at filePath: String) -> String? {
        guard let data = FileManager.default.contents(atPath: filePath),
            let xml = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let pattern = #"file://(/[^\s"\\}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(xml.startIndex..., in: xml)
        var candidates = Set<String>()
        for match in regex.matches(in: xml, range: nsRange) {
            guard let r = Range(match.range(at: 1), in: xml) else { continue }
            candidates.insert(String(xml[r]))
        }
        // 项目根目录通常是最浅（路径最短）的那条候选
        return candidates.min(by: { $0.count < $1.count })
    }

    /// 解析 JetBrains recentProjects.xml 内容，按最后打开时间降序返回。
    /// 提取为静态方法以便单元测试。
    static func parseJetBrainsRecentProjectsXML(_ xml: String, ideType: IDEType, limit: Int)
        -> [IDEProject]
    {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        var projects: [IDEProject] = []
        var seenPaths = Set<String>()  // 用于去重

        // 现代 JetBrains（含 IDEA 2026.1）把最近项目存放在 additionalInfo 的 <entry> map 中。
        // 重要：XML 中 entry 的顺序是"首次加入"的插入顺序，并非最近打开顺序；
        // 每个项目的最近激活时间记录在块内的 activationTimestamp（毫秒时间戳）里，
        // 必须读取它并按时间排序，最近打开的项目才会出现在列表最前。
        for entry in parseJetBrainsEntries(xml) {
            // 去重 + 跳过不存在的路径
            guard !seenPaths.contains(entry.path),
                FileManager.default.fileExists(atPath: entry.path)
            else {
                continue
            }
            seenPaths.insert(entry.path)

            let name = (entry.path as NSString).lastPathComponent
            projects.append(
                IDEProject(
                    name: name,
                    path: entry.path,
                    lastOpened: entry.lastOpened,
                    ideType: ideType
                ))
        }

        // 兜底：极老版本只有 recentPaths 列表（<option value="...">），不含 entry map，
        // 此时无法获取时间戳，仅按文件中出现顺序返回。
        if projects.isEmpty {
            let legacyPattern = #"<option value="([^"]+)"(?:/)?>"#
            if let regex = try? NSRegularExpression(pattern: legacyPattern) {
                for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
                    guard let range = Range(match.range(at: 1), in: xml) else { continue }

                    let projectPath = String(xml[range])
                        .replacingOccurrences(of: "$USER_HOME$", with: homeDir)

                    guard !seenPaths.contains(projectPath),
                        FileManager.default.fileExists(atPath: projectPath)
                    else {
                        continue
                    }
                    seenPaths.insert(projectPath)

                    let name = (projectPath as NSString).lastPathComponent
                    projects.append(
                        IDEProject(name: name, path: projectPath, ideType: ideType))
                }
            }
        }

        // 按最后打开时间降序排序（最近打开的排最前），无时间戳的排到最后
        projects.sort { lhs, rhs in
            switch (lhs.lastOpened, rhs.lastOpened) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return false
            }
        }

        // 排序后再截断，确保拿到的是最近打开的若干个（而非 XML 中靠前的若干个）
        return projects.count > limit ? Array(projects.prefix(limit)) : projects
    }

    /// 从 recentProjects.xml 解析出原始 entry 列表：项目路径、workspaceId、最近打开时间。
    /// 不做去重、不排序、不截断，也不检查路径是否存在——供合并逻辑与上面的 XML 解析共用。
    static func parseJetBrainsEntries(_ xml: String)
        -> [(path: String, workspaceId: String?, lastOpened: Date?)]
    {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        var entries: [(path: String, workspaceId: String?, lastOpened: Date?)] = []

        let entryPattern = #"<entry\s+key="([^"]+)"[^>]*>([\s\S]*?)</entry>"#
        guard let entryRegex = try? NSRegularExpression(pattern: entryPattern) else {
            return entries
        }
        for match in entryRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let keyRange = Range(match.range(at: 1), in: xml),
                let bodyRange = Range(match.range(at: 2), in: xml)
            else {
                continue
            }
            let projectPath = String(xml[keyRange])
                .replacingOccurrences(of: "$USER_HOME$", with: homeDir)
            let body = String(xml[bodyRange])
            entries.append(
                (
                    path: projectPath,
                    workspaceId: parseJetBrainsWorkspaceId(in: body),
                    lastOpened: parseJetBrainsTimestamp(in: body)
                ))
        }
        return entries
    }

    /// 从 <entry> 块内容中解析 projectWorkspaceId（workspace/ 目录下的文件名即此值）。
    private static func parseJetBrainsWorkspaceId(in body: String) -> String? {
        let pattern = #"projectWorkspaceId="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
            let range = Range(match.range(at: 1), in: body)
        else {
            return nil
        }
        return String(body[range])
    }

    /// 从 <entry> 块内容中解析最后打开时间。
    /// 优先 activationTimestamp（最近激活时间），其次退回到 projectOpenTimestamp（首次打开时间）。
    /// 时间戳为毫秒级 Unix 时间。
    private static func parseJetBrainsTimestamp(in body: String) -> Date? {
        for key in ["activationTimestamp", "projectOpenTimestamp"] {
            let pattern = "<option name=\"" + key + "\" value=\"(\\d+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                let range = Range(match.range(at: 1), in: body),
                let ms = Double(body[range])
            else {
                continue
            }
            return Date(timeIntervalSince1970: ms / 1000.0)
        }
        return nil
    }

    // MARK: - Antigravity

    private func getAntigravityRecentProjects(limit: Int) -> [IDEProject] {
        // Antigravity 使用类似 VSCode 的数据库结构
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            return []
        }

        do {
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath, "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';",
                ])
            guard !jsonString.isEmpty else { return [] }

            return parseAntigravityRecentProjects(jsonString, limit: limit)
        } catch {
            print("Failed to query Antigravity database: \(error)")
            return []
        }
    }

    private func parseAntigravityRecentProjects(_ jsonString: String, limit: Int) -> [IDEProject]
    {
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
                    ideType: .antigravity
                ))
        }

        return projects
    }

    // MARK: - Remove Recent Projects

    /// 从最近项目列表中移除指定项目
    /// - Parameters:
    ///   - ideType: IDE类型
    ///   - projectPath: 项目路径
    func removeRecentProject(for ideType: IDEType, projectPath: String) {
        switch ideType {
        case .vscode:
            removeVSCodeRecentProject(projectPath: projectPath)
        case .cursor:
            removeCursorRecentProject(projectPath: projectPath)
        case .zed:
            removeZedRecentProject(projectPath: projectPath)
        case .antigravity:
            removeAntigravityRecentProject(projectPath: projectPath)
        default:
            if ideType.isJetBrains {
                removeJetBrainsRecentProject(for: ideType, projectPath: projectPath)
            }
        }
    }

    /// 从VSCode最近项目列表中移除项目
    private func removeVSCodeRecentProject(projectPath: String) {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            // 1. 读取当前数据
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath,
                    "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';"
                ]
            )
            guard !jsonString.isEmpty else { return }

            // 2. 解析JSON并过滤
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var entries = json["entries"] as? [[String: Any]]
            else { return }

            // 3. 过滤掉要移除的项目
            let filteredEntries = entries.filter { entry in
                let path = extractPathFromEntry(entry)
                return path != projectPath
            }

            // 4. 写回数据库
            var modifiedJson: [String: Any] = ["entries": filteredEntries]
            let modifiedData = try JSONSerialization.data(withJSONObject: modifiedJson)
            let modifiedString = String(data: modifiedData, encoding: .utf8) ?? ""

            // 使用UPDATE语句更新
            let escapedValue = modifiedString.replacingOccurrences(of: "'", with: "''")
            let updateSQL = "UPDATE ItemTable SET value = '\(escapedValue)' WHERE key='history.recentlyOpenedPathsList';"

            try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [dbPath, updateSQL]
            )
        } catch {
            print("Failed to remove VSCode recent project: \(error)")
        }
    }

    /// 从Cursor最近项目列表中移除项目
    private func removeCursorRecentProject(projectPath: String) {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            // 1. 读取当前数据
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath,
                    "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';"
                ]
            )
            guard !jsonString.isEmpty else { return }

            // 2. 解析JSON并过滤
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var entries = json["entries"] as? [[String: Any]]
            else { return }

            // 3. 过滤掉要移除的项目
            let filteredEntries = entries.filter { entry in
                let path = extractPathFromEntry(entry)
                return path != projectPath
            }

            // 4. 写回数据库
            var modifiedJson: [String: Any] = ["entries": filteredEntries]
            let modifiedData = try JSONSerialization.data(withJSONObject: modifiedJson)
            let modifiedString = String(data: modifiedData, encoding: .utf8) ?? ""

            let escapedValue = modifiedString.replacingOccurrences(of: "'", with: "''")
            let updateSQL = "UPDATE ItemTable SET value = '\(escapedValue)' WHERE key='history.recentlyOpenedPathsList';"

            try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [dbPath, updateSQL]
            )
        } catch {
            print("Failed to remove Cursor recent project: \(error)")
        }
    }

    /// 从Zed最近项目列表中移除项目
    private func removeZedRecentProject(projectPath: String) {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zed/db/0-stable/db.sqlite")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            // Zed使用workspaces表,直接DELETE即可
            let deleteSQL = "DELETE FROM workspaces WHERE paths = '\(projectPath)';"

            try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [dbPath, deleteSQL]
            )
        } catch {
            print("Failed to remove Zed recent project: \(error)")
        }
    }

    /// 从Antigravity最近项目列表中移除项目
    private func removeAntigravityRecentProject(projectPath: String) {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Antigravity/User/globalStorage/state.vscdb"
            )
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return }

        do {
            // 1. 读取当前数据
            let jsonString = try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [
                    dbPath,
                    "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList';"
                ]
            )
            guard !jsonString.isEmpty else { return }

            // 2. 解析JSON并过滤
            guard let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var entries = json["entries"] as? [[String: Any]]
            else { return }

            // 3. 过滤掉要移除的项目
            let filteredEntries = entries.filter { entry in
                let path = extractPathFromEntry(entry)
                return path != projectPath
            }

            // 4. 写回数据库
            var modifiedJson: [String: Any] = ["entries": filteredEntries]
            let modifiedData = try JSONSerialization.data(withJSONObject: modifiedJson)
            let modifiedString = String(data: modifiedData, encoding: .utf8) ?? ""

            let escapedValue = modifiedString.replacingOccurrences(of: "'", with: "''")
            let updateSQL = "UPDATE ItemTable SET value = '\(escapedValue)' WHERE key='history.recentlyOpenedPathsList';"

            try Self.runCommand(
                executablePath: "/usr/bin/sqlite3",
                arguments: [dbPath, updateSQL]
            )
        } catch {
            print("Failed to remove Antigravity recent project: \(error)")
        }
    }

    /// 从JetBrains IDE最近项目列表中移除项目
    private func removeJetBrainsRecentProject(for ideType: IDEType, projectPath: String) {
        // 查找JetBrains配置目录
        let appSupportPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/JetBrains")
            .path

        guard FileManager.default.fileExists(atPath: appSupportPath) else { return }

        // 根据IDE类型确定目录前缀
        let dirPrefix: String
        switch ideType {
        case .jetbrainsIntelliJ: dirPrefix = "IntelliJIdea"
        case .jetbrainsPyCharm: dirPrefix = "PyCharm"
        case .jetbrainsWebStorm: dirPrefix = "WebStorm"
        case .jetbrainsGoLand: dirPrefix = "GoLand"
        case .jetbrainsRider: dirPrefix = "Rider"
        case .jetbrainsClion: dirPrefix = "CLion"
        default: return
        }

        // 查找最新版本的配置目录
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appSupportPath)
        else { return }

        let matchingDirs = contents.filter { $0.hasPrefix(dirPrefix) }.sorted().reversed()

        for dir in matchingDirs {
            let recentProjectsPath = (appSupportPath as NSString)
                .appendingPathComponent(dir)
                .appending("/options/recentProjects.xml")

            if FileManager.default.fileExists(atPath: recentProjectsPath) {
                removeProjectFromJetBrainsXML(at: recentProjectsPath, projectPath: projectPath)
                break
            }
        }
    }

    /// 从JetBrains XML文件中移除项目
    private func removeProjectFromJetBrainsXML(at path: String, projectPath: String) {
        guard let data = FileManager.default.contents(atPath: path),
              var xml = String(data: data, encoding: .utf8)
        else { return }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let xmlPath = projectPath.replacingOccurrences(of: homeDir, with: "$USER_HOME$")

        // 简单的XML处理:移除包含该路径的entry或option行
        let lines = xml.components(separatedBy: "\n")
        let filteredLines = lines.filter { line in
            !line.contains(xmlPath)
        }

        let modifiedXML = filteredLines.joined(separator: "\n")

        do {
            try modifiedXML.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            print("Failed to remove JetBrains recent project: \(error)")
        }
    }

    /// 从entry字典中提取路径
    private func extractPathFromEntry(_ entry: [String: Any]) -> String? {
        // 优先获取folderUri(项目文件夹)
        if let folderUri = entry["folderUri"] as? String {
            return uriToPath(folderUri)
        }
        // 其次获取workspace(工作区文件)
        else if let workspace = entry["workspace"] as? String {
            // 工作区文件,取其所在目录
            if let wsPath = uriToPath(workspace) {
                return (wsPath as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// 将 file:// URI 转换为路径
    private func uriToPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }

        // 移除 file:// 前缀并解码 URL 编码
        let encoded = String(uri.dropFirst(7))
        return encoded.removingPercentEncoding
    }

    static func runCommand(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        // 先持续读取 stdout，避免子进程在管道缓冲区写满后阻塞，导致 waitUntilExit 互锁。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CommandError.nonZeroExitStatus(process.terminationStatus)
        }

        guard let output = String(data: data, encoding: .utf8) else {
            throw CommandError.invalidUTF8
        }

        return output
    }
}
