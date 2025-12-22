import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search Settings View

struct SearchSettingsView: View {
    @StateObject private var viewModel = SearchSettingsViewModel()

    var body: some View {
        HSplitView {
            // 左侧菜单
            VStack(alignment: .leading, spacing: 0) {
                Text("搜索设置")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                SidebarItem(
                    icon: "doc.text",
                    title: "文档搜索",
                    color: .orange,
                    isSelected: viewModel.selectedSection == .documentSearch
                ) {
                    viewModel.selectedSection = .documentSearch
                }

                SidebarItem(
                    icon: "app.badge",
                    title: "应用搜索",
                    color: .blue,
                    isSelected: viewModel.selectedSection == .appSearch
                ) {
                    viewModel.selectedSection = .appSearch
                }

                Text("隐私设置")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                SidebarItem(
                    icon: "eye.slash",
                    title: "文档搜索排除",
                    color: .purple,
                    isSelected: viewModel.selectedSection == .exclusions
                ) {
                    viewModel.selectedSection = .exclusions
                }

                Spacer()
            }
            .frame(width: 160)
            .background(Color(nsColor: .controlBackgroundColor))

            // 右侧内容
            VStack {
                switch viewModel.selectedSection {
                case .documentSearch:
                    DocumentSearchSettingsView(viewModel: viewModel)
                case .appSearch:
                    AppSearchSettingsView(viewModel: viewModel)
                case .exclusions:
                    ExclusionsSettingsView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar Item

struct SidebarItem: View {
    let icon: String
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 20)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

// MARK: - Document Search Settings

struct DocumentSearchSettingsView: View {
    @ObservedObject var viewModel: SearchSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with buttons
            HStack {
                Text("文档搜索范围")
                    .font(.headline)

                Spacer()

                Button("重建索引") {
                    viewModel.rebuildSpotlightIndex()
                }
                .buttonStyle(.bordered)

                Button("索引检查") {
                    viewModel.checkIndexStatus()
                }
                .buttonStyle(.bordered)

                Button("恢复默认") {
                    viewModel.resetDocumentScopes()
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.addDocumentScope() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }

            // Scope list
            List {
                ForEach(viewModel.documentScopes, id: \.self) { scope in
                    HStack {
                        Image(systemName: folderIcon(for: scope))
                            .foregroundColor(.blue)
                        Text(scope.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Spacer()
                        Button(action: { viewModel.removeDocumentScope(scope) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered)

            // Warning
            HStack {
                Image(systemName: "lightbulb")
                    .foregroundColor(.yellow)
                Text("勿添加系统文档路径，过大的搜索范围将无谓的消耗更多的电脑资源。可添加 APFS 及扩展日志格式的外置磁盘路径。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(20)
    }

    private func folderIcon(for path: String) -> String {
        if path.contains("Downloads") { return "arrow.down.circle" }
        if path.contains("Documents") { return "doc.circle" }
        if path.contains("Desktop") { return "desktopcomputer" }
        if path.contains("dev") { return "folder" }
        return "folder"
    }
}

// MARK: - App Search Settings

struct AppSearchSettingsView: View {
    @ObservedObject var viewModel: SearchSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("应用搜索范围")
                    .font(.headline)

                Spacer()

                Button("恢复默认") {
                    viewModel.resetAppScopes()
                }
                .buttonStyle(.bordered)

                Button(action: { viewModel.addAppScope() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
            }

            List {
                ForEach(viewModel.appScopes, id: \.self) { scope in
                    HStack {
                        Image(systemName: "app.badge")
                            .foregroundColor(.blue)
                        Text(scope)
                        Spacer()
                        Button(action: { viewModel.removeAppScope(scope) }) {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.bordered)
        }
        .padding(20)
    }
}

// MARK: - Exclusions Settings

struct ExclusionsSettingsView: View {
    @ObservedObject var viewModel: SearchSettingsViewModel
    @State private var showAddMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("搜索排除")
                    .font(.headline)

                Spacer()

                Menu {
                    Text("添加索引排除")
                        .font(.caption)
                    Divider()
                    Button("路径") { viewModel.addExcludedPath() }
                    Button("文档后缀") { viewModel.addExcludedExtension() }
                    Button("文件夹名称") { viewModel.addExcludedFolderName() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }

            List {
                // Excluded Paths
                DisclosureGroup("按路径排除 (\(viewModel.excludedPaths.count))") {
                    ForEach(viewModel.excludedPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                                .foregroundColor(.red)
                            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            Spacer()
                            Button(action: { viewModel.removeExcludedPath(path) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Excluded Extensions
                DisclosureGroup("按后缀排除 (\(viewModel.excludedExtensions.count))") {
                    ForEach(viewModel.excludedExtensions, id: \.self) { ext in
                        HStack {
                            Image(systemName: "doc.badge.minus")
                                .foregroundColor(.orange)
                            Text(".\(ext)")
                            Spacer()
                            Button(action: { viewModel.removeExcludedExtension(ext) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Excluded Folder Names
                DisclosureGroup("按文件夹名称排除 (\(viewModel.excludedFolderNames.count))") {
                    ForEach(viewModel.excludedFolderNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                                .foregroundColor(.purple)
                            Text(name)
                            Spacer()
                            Button(action: { viewModel.removeExcludedFolderName(name) }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.bordered)
        }
        .padding(20)
    }
}

// MARK: - View Model

class SearchSettingsViewModel: ObservableObject {
    enum Section {
        case documentSearch
        case appSearch
        case exclusions
    }

    @Published var selectedSection: Section = .documentSearch
    @Published var documentScopes: [String] = []
    @Published var appScopes: [String] = []
    @Published var excludedPaths: [String] = []
    @Published var excludedExtensions: [String] = []
    @Published var excludedFolderNames: [String] = []

    private var config: SearchConfig

    init() {
        self.config = SearchConfig.load()
        loadFromConfig()
    }

    private func loadFromConfig() {
        documentScopes = config.documentScopes
        appScopes = config.appScopes
        excludedPaths = config.excludedPaths
        excludedExtensions = config.excludedExtensions
        excludedFolderNames = config.excludedFolderNames
    }

    private func saveConfig() {
        config.documentScopes = documentScopes
        config.appScopes = appScopes
        config.excludedPaths = excludedPaths
        config.excludedExtensions = excludedExtensions
        config.excludedFolderNames = excludedFolderNames
        config.save()

        // Notify MetadataQueryService to reload
        NotificationCenter.default.post(name: .searchConfigDidChange, object: config)
    }

    // MARK: - Document Scopes

    func addDocumentScope() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择文件夹进入文档的搜索范围"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !documentScopes.contains(path) {
                    documentScopes.append(path)
                }
            }
            saveConfig()
        }
    }

    func removeDocumentScope(_ scope: String) {
        documentScopes.removeAll { $0 == scope }
        saveConfig()
    }

    func resetDocumentScopes() {
        documentScopes = SearchConfig.defaultDocumentScopes
        saveConfig()
    }

    func rebuildSpotlightIndex() {
        let alert = NSAlert()
        alert.messageText = "重建 Spotlight 索引"
        alert.informativeText = "这将重建 LaunchX 的搜索索引。确定继续吗？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重建")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            // Trigger re-indexing
            let config = SearchConfig.load()
            NotificationCenter.default.post(name: .searchConfigDidChange, object: config)

            // Show confirmation
            let confirmAlert = NSAlert()
            confirmAlert.messageText = "索引重建已开始"
            confirmAlert.informativeText = "索引正在后台重建，完成后搜索结果将自动更新。"
            confirmAlert.runModal()
        }
    }

    func checkIndexStatus() {
        let service = MetadataQueryService.shared
        let alert = NSAlert()
        alert.messageText = "LaunchX 已索引文档数量：\(service.indexedItemCount)"

        var info = "📊 索引用时：\(String(format: "%.3f", service.indexingDuration))s"

        if let lastTime = service.lastIndexTime {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
            info += "\n📅 最后更新时间：\(formatter.string(from: lastTime))"
        }

        info += "\n\n📱 应用数量：\(service.appsCount)"
        info += "\n📄 文件数量：\(service.filesCount)"

        alert.informativeText = info
        alert.runModal()
    }

    // MARK: - App Scopes

    func addAppScope() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择应用程序文件夹"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !appScopes.contains(path) {
                    appScopes.append(path)
                }
            }
            saveConfig()
        }
    }

    func removeAppScope(_ scope: String) {
        appScopes.removeAll { $0 == scope }
        saveConfig()
    }

    func resetAppScopes() {
        appScopes = SearchConfig.defaultAppScopes
        saveConfig()
    }

    // MARK: - Exclusions

    func addExcludedPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择要排除的路径"

        if panel.runModal() == .OK {
            for url in panel.urls {
                let path = url.path
                if !excludedPaths.contains(path) {
                    excludedPaths.append(path)
                }
            }
            saveConfig()
        }
    }

    func removeExcludedPath(_ path: String) {
        excludedPaths.removeAll { $0 == path }
        saveConfig()
    }

    func addExcludedExtension() {
        let alert = NSAlert()
        alert.messageText = "添加排除的文件后缀"
        alert.informativeText = "输入文件后缀名（不含点号）"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "例如: log, tmp, bak"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let ext = textField.stringValue.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ".", with: "")
            if !ext.isEmpty && !excludedExtensions.contains(ext) {
                excludedExtensions.append(ext)
                saveConfig()
            }
        }
    }

    func removeExcludedExtension(_ ext: String) {
        excludedExtensions.removeAll { $0 == ext }
        saveConfig()
    }

    func addExcludedFolderName() {
        let alert = NSAlert()
        alert.messageText = "添加排除的文件夹名称"
        alert.informativeText = "输入文件夹名称（会全局排除）"
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "例如: node_modules, .git"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let name = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !excludedFolderNames.contains(name) {
                excludedFolderNames.append(name)
                saveConfig()
            }
        }
    }

    func removeExcludedFolderName(_ name: String) {
        excludedFolderNames.removeAll { $0 == name }
        saveConfig()
    }
}

// MARK: - Notification

extension Notification.Name {
    static let searchConfigDidChange = Notification.Name("searchConfigDidChange")
}

#Preview {
    SearchSettingsView()
        .frame(width: 550, height: 400)
}
