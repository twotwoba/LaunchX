import AppKit
import Foundation

/// IDE 类型枚举
enum IDEType: String, CaseIterable {
    case vscode = "Visual Studio Code"
    case cursor = "Cursor"
    case zed = "Zed"
    case antigravity = "Antigravity"
    case winc = "Winc"
    case jetbrainsIntelliJ = "IntelliJ IDEA"
    case jetbrainsPyCharm = "PyCharm"
    case jetbrainsWebStorm = "WebStorm"
    case jetbrainsGoLand = "GoLand"
    case jetbrainsRider = "Rider"
    case jetbrainsClion = "CLion"

    /// 应用的 bundle identifier (支持多个版本)
    var bundleIdentifiers: [String] {
        switch self {
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .zed: return ["dev.zed.Zed", "dev.zed.Zed-Preview", "dev.zed.Zed-Nightly"]
        case .antigravity: return ["com.google.Antigravity", "com.google.AntigravityPreview"]
        case .winc: return ["com.deeix.winc"]
        case .jetbrainsIntelliJ:
            return [
                "com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.intellij-EAP",
            ]
        case .jetbrainsPyCharm:
            return [
                "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce", "com.jetbrains.pycharm-EAP",
            ]
        case .jetbrainsWebStorm: return ["com.jetbrains.WebStorm", "com.jetbrains.WebStorm-EAP"]
        case .jetbrainsGoLand: return ["com.jetbrains.goland", "com.jetbrains.goland-EAP"]
        case .jetbrainsRider: return ["com.jetbrains.rider", "com.jetbrains.rider-EAP"]
        case .jetbrainsClion: return ["com.jetbrains.CLion", "com.jetbrains.CLion-EAP"]
        }
    }

    /// 是否为 JetBrains 系列
    var isJetBrains: Bool {
        switch self {
        case .vscode, .cursor, .zed, .antigravity, .winc: return false
        default: return true
        }
    }

    /// 从应用路径检测 IDE 类型
    static func detect(from path: String) -> IDEType? {
        let lowercasedPath = path.lowercased()

        if lowercasedPath.contains("visual studio code") || lowercasedPath.hasSuffix("/code.app") {
            return .vscode
        }
        if lowercasedPath.contains("cursor") || lowercasedPath.hasSuffix("/cursor.app") {
            return .cursor
        }
        if lowercasedPath.hasSuffix("/zed.app") {
            return .zed
        }
        if lowercasedPath.contains("antigravity") || lowercasedPath.hasSuffix("/antigravity.app") {
            return .antigravity
        }
        // 只按 .app 后缀严格匹配，避免把名为 winc 的普通目录（如源码目录）误判为 Winc 应用
        if lowercasedPath.hasSuffix("/winc.app") {
            return .winc
        }
        if lowercasedPath.contains("intellij") {
            return .jetbrainsIntelliJ
        }
        if lowercasedPath.contains("pycharm") {
            return .jetbrainsPyCharm
        }
        if lowercasedPath.contains("webstorm") {
            return .jetbrainsWebStorm
        }
        if lowercasedPath.contains("goland") {
            return .jetbrainsGoLand
        }
        if lowercasedPath.contains("rider") {
            return .jetbrainsRider
        }
        if lowercasedPath.contains("clion") {
            return .jetbrainsClion
        }

        return nil
    }
}

/// IDE 项目数据模型
struct IDEProject: Identifiable, Hashable {
    let id: UUID
    let name: String  // 项目名称（文件夹名）
    let path: String  // 完整路径
    let displayPath: String  // 显示路径（简化的）
    let lastOpened: Date?  // 最后打开时间
    let ideType: IDEType  // 所属 IDE 类型

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        lastOpened: Date? = nil,
        ideType: IDEType
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.lastOpened = lastOpened
        self.ideType = ideType

        // 生成简化的显示路径
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            let relativePath = String(path.dropFirst(homeDir.count))
            self.displayPath = "~" + relativePath
        } else {
            self.displayPath = path
        }
    }

    /// 转换为 SearchResult 用于 UI 显示
    func toSearchResult() -> SearchResult {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)

        return SearchResult(
            id: id,
            name: name,
            path: path,
            icon: icon,
            isDirectory: true
        )
    }

    static func == (lhs: IDEProject, rhs: IDEProject) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
