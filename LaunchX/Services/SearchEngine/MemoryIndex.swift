import Cocoa
import Foundation

/// High-performance in-memory search index
/// Provides O(1) prefix matching using Trie data structure
final class MemoryIndex {

    // MARK: - Data Structures

    /// Trie node for prefix matching
    private class TrieNode {
        var children: [Character: TrieNode] = [:]
        var items: [SearchItem] = []
        var isEndOfWord = false
    }

    /// Indexed search item (lightweight, stored in memory)
    final class SearchItem {
        let name: String
        let lowerName: String
        let path: String
        let lowerFileName: String
        let isApp: Bool
        let isDirectory: Bool
        let isWebLink: Bool  // 是否为网页直达
        let modifiedDate: Date
        let pinyinFull: String?
        let pinyinAcronym: String?

        // English word acronym (e.g., "vsc" for "Visual Studio Code")
        let wordAcronym: String?

        // Lazy-loaded icon
        private var _icon: NSImage?
        var icon: NSImage {
            if _icon == nil {
                _icon = NSWorkspace.shared.icon(forFile: path)
                _icon?.size = NSSize(width: 32, height: 32)
            }
            return _icon ?? NSImage()
        }

        init(from record: FileRecord) {
            self.name = record.name
            self.lowerName = record.name.lowercased()
            self.path = record.path
            self.lowerFileName = (record.path as NSString).lastPathComponent.lowercased()
            self.isApp = record.isApp
            self.isDirectory = record.isDirectory
            self.isWebLink = false  // 文件系统项目不是网页直达
            self.modifiedDate = record.modifiedDate ?? Date.distantPast
            self.pinyinFull = record.pinyinFull
            self.pinyinAcronym = record.pinyinAcronym

            // Generate word acronym for multi-word names (e.g., "Visual Studio Code" -> "vsc")
            self.wordAcronym = SearchItem.generateWordAcronym(from: record.name)
        }

        /// 用于创建网页直达等非文件系统项目
        init(
            name: String, path: String, isWebLink: Bool, iconData: Data? = nil, alias: String? = nil
        ) {
            self.name = name
            self.lowerName = name.lowercased()
            self.path = path
            self.lowerFileName = name.lowercased()
            self.isApp = false
            self.isDirectory = false
            self.isWebLink = isWebLink  // 存储网页直达标记
            self.modifiedDate = Date()
            self.pinyinFull = nil
            self.pinyinAcronym = nil
            self.wordAcronym = SearchItem.generateWordAcronym(from: name)
            self._displayAlias = alias

            // 设置图标：优先使用自定义图标
            if let data = iconData, let customIcon = NSImage(data: data) {
                customIcon.size = NSSize(width: 32, height: 32)
                self._icon = customIcon
            } else if isWebLink {
                self._icon = NSImage(
                    systemSymbolName: "globe", accessibilityDescription: "Web Link")
                self._icon?.size = NSSize(width: 32, height: 32)
            }
        }

        // 存储别名（用于显示）
        private var _displayAlias: String?
        var displayAlias: String? { _displayAlias }

        /// Generate acronym from first letter of each word
        /// "Visual Studio Code" -> "vsc", "Activity Monitor" -> "am"
        private static func generateWordAcronym(from name: String) -> String? {
            // Split by spaces, hyphens, underscores
            let words = name.components(separatedBy: CharacterSet(charactersIn: " -_"))
                .filter { !$0.isEmpty }

            // Only generate if multiple words
            guard words.count > 1 else { return nil }

            var acronym = ""
            for word in words {
                if let first = word.first, first.isLetter {
                    acronym.append(first.lowercased())
                }
            }

            return acronym.isEmpty ? nil : acronym
        }

        /// Match type for sorting priority
        enum MatchType: Int, Comparable {
            case exact = 0
            case prefix = 1
            case contains = 2
            case pinyin = 3

            static func < (lhs: MatchType, rhs: MatchType) -> Bool {
                return lhs.rawValue < rhs.rawValue
            }
        }

        /// Check if matches query
        func matchesQuery(_ lowerQuery: String) -> MatchType? {
            if lowerName == lowerQuery || lowerFileName == lowerQuery {
                return .exact
            }
            if lowerName.hasPrefix(lowerQuery) || lowerFileName.hasPrefix(lowerQuery) {
                return .prefix
            }
            if lowerName.contains(lowerQuery) || lowerFileName.contains(lowerQuery) {
                return .contains
            }
            return nil
        }

        /// Check pinyin match or word acronym match
        func matchesPinyin(_ lowerQuery: String) -> Bool {
            // Check Chinese pinyin acronym (e.g., "wx" for "微信")
            if let acronym = pinyinAcronym, acronym.hasPrefix(lowerQuery) {
                return true
            }
            // Check Chinese pinyin full (e.g., "weixin" for "微信")
            if let full = pinyinFull {
                if full.hasPrefix(lowerQuery) || full.contains(lowerQuery) {
                    return true
                }
            }
            // Check English word acronym (e.g., "vsc" for "Visual Studio Code")
            if let acronym = wordAcronym, acronym.hasPrefix(lowerQuery) {
                return true
            }
            return false
        }

        /// Convert to SearchResult for UI
        func toSearchResult() -> SearchResult {
            return SearchResult(
                id: UUID(),
                name: name,
                path: path,
                icon: icon,
                isDirectory: isDirectory,
                displayAlias: displayAlias,
                isWebLink: path.hasPrefix("http://") || path.hasPrefix("https://")
            )
        }
    }

    // MARK: - Properties

    private var apps: [SearchItem] = []
    private var files: [SearchItem] = []
    private var directories: [SearchItem] = []  // 单独存储目录，便于搜索
    private var tools: [SearchItem] = []  // 工具项目（网页直达等非文件系统项目）
    private var allItems: [String: SearchItem] = [:]  // path -> item for O(1) lookup

    private var nameTrie = TrieNode()
    private var pinyinTrie = TrieNode()

    // 别名支持
    private var aliasMap: [String: String] = [:]  // alias (lowercase) -> path
    private var aliasTrie = TrieNode()

    // 串行队列保证线程安全，所有数据访问都通过这个队列
    private let queue = DispatchQueue(label: "com.launchx.memoryindex", qos: .userInteractive)

    // Statistics
    private(set) var appsCount: Int = 0
    private(set) var filesCount: Int = 0
    private(set) var directoriesCount: Int = 0
    private(set) var totalCount: Int = 0

    // MARK: - Building Index

    /// Build index from database records
    func build(from records: [FileRecord], completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let startTime = Date()

            // Clear existing index
            self.apps.removeAll()
            self.files.removeAll()
            self.directories.removeAll()
            self.allItems.removeAll()
            self.nameTrie = TrieNode()
            self.pinyinTrie = TrieNode()

            // Reserve capacity
            self.apps.reserveCapacity(500)
            self.files.reserveCapacity(records.count)
            self.directories.reserveCapacity(5000)
            self.allItems.reserveCapacity(records.count)

            // Build items
            for record in records {
                let item = SearchItem(from: record)
                self.allItems[item.path] = item

                if item.isApp {
                    self.apps.append(item)
                } else if item.isDirectory {
                    self.directories.append(item)
                } else {
                    self.files.append(item)
                }

                // Insert into name trie
                self.insertIntoTrie(self.nameTrie, key: item.lowerName, item: item)

                // Insert into pinyin trie
                if let pinyin = item.pinyinFull {
                    self.insertIntoTrie(self.pinyinTrie, key: pinyin, item: item)
                }
                if let acronym = item.pinyinAcronym {
                    self.insertIntoTrie(self.pinyinTrie, key: acronym, item: item)
                }
            }

            // Sort apps by name length (shorter = more relevant)
            self.apps.sort { $0.name.count < $1.name.count }

            // Sort directories by modified date (recent first)
            self.directories.sort { $0.modifiedDate > $1.modifiedDate }

            // Sort files by modified date (recent first)
            self.files.sort { $0.modifiedDate > $1.modifiedDate }

            // Update statistics
            self.appsCount = self.apps.count
            self.filesCount = self.files.count
            self.directoriesCount = self.directories.count
            self.totalCount = self.allItems.count

            let duration = Date().timeIntervalSince(startTime)
            print(
                "MemoryIndex: Built index with \(self.totalCount) items (\(self.appsCount) apps, \(self.directoriesCount) dirs, \(self.filesCount) files) in \(String(format: "%.3f", duration))s"
            )

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// Add a single item to index (用于实时更新)
    func add(_ record: FileRecord) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let item = SearchItem(from: record)

            // 检查是否已存在
            if self.allItems[item.path] != nil {
                // 已存在则跳过，不需要重复添加
                return
            }

            self.allItems[item.path] = item

            if item.isApp {
                self.apps.append(item)
                self.apps.sort { $0.name.count < $1.name.count }
                self.appsCount = self.apps.count
            } else if item.isDirectory {
                self.directories.insert(item, at: 0)  // Insert at beginning (most recent)
                self.directoriesCount = self.directories.count
            } else {
                self.files.insert(item, at: 0)  // Insert at beginning (most recent)
                self.filesCount = self.files.count
            }

            self.insertIntoTrie(self.nameTrie, key: item.lowerName, item: item)

            if let pinyin = item.pinyinFull {
                self.insertIntoTrie(self.pinyinTrie, key: pinyin, item: item)
            }
            if let acronym = item.pinyinAcronym {
                self.insertIntoTrie(self.pinyinTrie, key: acronym, item: item)
            }

            self.totalCount = self.allItems.count
        }
    }

    /// Remove an item from index
    func remove(path: String) {
        queue.async { [weak self] in
            guard let self = self, let item = self.allItems[path] else { return }

            self.allItems.removeValue(forKey: path)

            if item.isApp {
                if let index = self.apps.firstIndex(where: { $0.path == path }) {
                    self.apps.remove(at: index)
                }
                self.appsCount = self.apps.count
            } else if item.isDirectory {
                if let index = self.directories.firstIndex(where: { $0.path == path }) {
                    self.directories.remove(at: index)
                }
                self.directoriesCount = self.directories.count
            } else {
                if let index = self.files.firstIndex(where: { $0.path == path }) {
                    self.files.remove(at: index)
                }
                self.filesCount = self.files.count
            }

            // Note: Removing from Trie is complex, we skip it for now
            // The item will just be filtered out during search

            self.totalCount = self.allItems.count
        }
    }

    // MARK: - Search

    /// Synchronous search - must be extremely fast (< 5ms)
    /// 直接访问数据，不使用队列同步（搜索是只读的，数据一致性由调用方保证）
    func search(
        query: String,
        excludedApps: Set<String> = [],
        excludedPaths: [String] = [],
        excludedExtensions: Set<String> = [],
        excludedFolderNames: Set<String> = [],
        maxResults: Int = 30
    ) -> [SearchItem] {
        guard !query.isEmpty else { return [] }

        let lowerQuery = query.lowercased()
        let queryIsAscii = query.allSatisfy { $0.isASCII }

        var matchedApps: [(item: SearchItem, matchType: SearchItem.MatchType)] = []
        var matchedDirs: [(item: SearchItem, matchType: SearchItem.MatchType)] = []
        var matchedFiles: [(item: SearchItem, matchType: SearchItem.MatchType)] = []
        var aliasMatched: Set<String> = []  // 记录已通过别名匹配的路径

        matchedApps.reserveCapacity(10)
        matchedDirs.reserveCapacity(10)
        matchedFiles.reserveCapacity(20)

        // 0. 先搜索别名（最高优先级）
        // 工具类（网页直达、实用工具、系统命令）通过别名搜索时也应该排在前面
        let aliasResults = searchByAliasInternal(lowerQuery)
        for item in aliasResults {
            if excludedApps.contains(item.path) { continue }
            aliasMatched.insert(item.path)

            // 工具类（网页直达等）和应用都放入 matchedApps，以便优先显示
            if item.isApp || item.isWebLink {
                matchedApps.append((item, .exact))  // 别名匹配视为精确匹配
            } else if item.isDirectory {
                matchedDirs.append((item, .exact))
            } else {
                matchedFiles.append((item, .exact))
            }
        }

        // 1. Search Apps (fast, small list)
        // 复制引用避免并发问题
        let currentApps = apps
        for app in currentApps {
            if excludedApps.contains(app.path) { continue }
            if aliasMatched.contains(app.path) { continue }  // 跳过已通过别名匹配的

            if let matchType = app.matchesQuery(lowerQuery) {
                matchedApps.append((app, matchType))
                continue
            }

            if queryIsAscii && app.matchesPinyin(lowerQuery) {
                matchedApps.append((app, .pinyin))
            }
        }

        // 1.5 Search Tools (网页直达等非文件系统项目，通过名称搜索)
        let currentTools = tools
        for tool in currentTools {
            if aliasMatched.contains(tool.path) { continue }  // 跳过已通过别名匹配的

            if let matchType = tool.matchesQuery(lowerQuery) {
                // 工具项目放在应用列表中，优先级较高
                matchedApps.append((tool, matchType))
            }
        }

        // Sort apps (工具类优先，然后按匹配类型，最后按名称长度)
        matchedApps.sort {
            (
                lhs: (item: SearchItem, matchType: SearchItem.MatchType),
                rhs: (item: SearchItem, matchType: SearchItem.MatchType)
            ) in
            // 工具类（网页直达等）优先排在最前面
            if lhs.item.isWebLink != rhs.item.isWebLink {
                return lhs.item.isWebLink
            }
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.name.count < rhs.item.name.count
        }

        // 2. Search Directories (搜索全部目录，目录数量相对较少)
        let currentDirs = directories
        for dir in currentDirs {
            if aliasMatched.contains(dir.path) { continue }

            // Apply exclusions
            if excludedPaths.contains(where: { dir.path.hasPrefix($0) }) { continue }

            if !excludedFolderNames.isEmpty {
                let components = dir.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            if let matchType = dir.matchesQuery(lowerQuery) {
                matchedDirs.append((dir, matchType))
                if matchedDirs.count >= 10 { break }
                continue
            }

            if queryIsAscii && dir.matchesPinyin(lowerQuery) {
                matchedDirs.append((dir, .pinyin))
                if matchedDirs.count >= 10 { break }
            }
        }

        // Sort directories
        matchedDirs.sort { lhs, rhs in
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.modifiedDate > rhs.item.modifiedDate
        }

        // 3. Search Files
        // 策略：先用 Trie 快速获取前缀匹配（无数量限制），再用线性扫描补充 contains 匹配
        let currentFiles = files

        // 3a. 使用 Trie 获取前缀匹配的文件（突破 5000 限制）
        let trieCandidates = getTrieCandidates(query: query)
        for path in trieCandidates {
            guard let file = allItems[path], !file.isApp, !file.isDirectory else { continue }

            // Apply exclusions
            if excludedPaths.contains(where: { file.path.hasPrefix($0) }) { continue }

            if !excludedExtensions.isEmpty {
                let ext = (file.path as NSString).pathExtension.lowercased()
                if excludedExtensions.contains(ext) { continue }
            }

            if !excludedFolderNames.isEmpty {
                let components = file.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            // Trie 匹配的都是前缀匹配
            if let matchType = file.matchesQuery(lowerQuery) {
                matchedFiles.append((file, matchType))
            } else if queryIsAscii && file.matchesPinyin(lowerQuery) {
                matchedFiles.append((file, .pinyin))
            }
        }

        // 3b. 线性扫描补充 contains 匹配（仅在结果不足时）
        if matchedFiles.count < 20 {
            let maxFileIterations = min(currentFiles.count, 5000)
            var scannedPaths = Set(matchedFiles.map { $0.item.path })

            for i in 0..<maxFileIterations {
                if matchedFiles.count >= 20 { break }

                let file = currentFiles[i]

                // 跳过已经通过 Trie 匹配的
                if scannedPaths.contains(file.path) { continue }

                // Apply exclusions
                if excludedPaths.contains(where: { file.path.hasPrefix($0) }) { continue }

                if !excludedExtensions.isEmpty {
                    let ext = (file.path as NSString).pathExtension.lowercased()
                    if excludedExtensions.contains(ext) { continue }
                }

                if !excludedFolderNames.isEmpty {
                    let components = file.path.components(separatedBy: "/")
                    if !excludedFolderNames.isDisjoint(with: components) { continue }
                }

                if let matchType = file.matchesQuery(lowerQuery) {
                    matchedFiles.append((file, matchType))
                    continue
                }

                if queryIsAscii && file.matchesPinyin(lowerQuery) {
                    matchedFiles.append((file, .pinyin))
                }
            }
        }

        // Sort files
        matchedFiles.sort { lhs, rhs in
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.modifiedDate > rhs.item.modifiedDate
        }

        // Combine results: apps -> directories -> files
        // 使用 Set 去重，避免重复显示
        var seenPaths = Set<String>()
        var results: [SearchItem] = []
        results.reserveCapacity(30)

        for item in matchedApps.prefix(10).map({ $0.item }) {
            if seenPaths.insert(item.path).inserted {
                results.append(item)
            }
        }

        for item in matchedDirs.prefix(10).map({ $0.item }) {
            if seenPaths.insert(item.path).inserted {
                results.append(item)
            }
        }

        for item in matchedFiles.prefix(10).map({ $0.item }) {
            if seenPaths.insert(item.path).inserted {
                results.append(item)
            }
        }

        return results
    }

    /// 使用 Trie 快速获取前缀匹配的候选项
    /// 内部使用，用于加速搜索
    private func getTrieCandidates(query: String) -> Set<String> {
        let lowerQuery = query.lowercased()
        var candidatePaths = Set<String>()

        // 从 name trie 获取候选
        if let items = searchTrie(nameTrie, prefix: lowerQuery) {
            for item in items {
                candidatePaths.insert(item.path)
            }
        }

        // 从 pinyin trie 获取候选（仅 ASCII 查询）
        if query.allSatisfy({ $0.isASCII }) {
            if let items = searchTrie(pinyinTrie, prefix: lowerQuery) {
                for item in items {
                    candidatePaths.insert(item.path)
                }
            }
        }

        // 从 alias trie 获取候选
        if let items = searchTrie(aliasTrie, prefix: lowerQuery) {
            for item in items {
                candidatePaths.insert(item.path)
            }
        }

        return candidatePaths
    }

    // MARK: - Trie Operations

    private func insertIntoTrie(_ root: TrieNode, key: String, item: SearchItem) {
        var current = root

        for char in key {
            if current.children[char] == nil {
                current.children[char] = TrieNode()
            }
            current = current.children[char]!
            current.items.append(item)  // Store item at each prefix level
        }

        current.isEndOfWord = true
    }

    private func searchTrie(_ root: TrieNode, prefix: String) -> [SearchItem]? {
        var current = root

        for char in prefix {
            guard let next = current.children[char] else {
                return nil
            }
            current = next
        }

        return current.items
    }

    // MARK: - 别名支持

    /// 别名工具信息（用于非应用类型的工具）
    struct AliasToolInfo {
        let name: String
        let path: String  // 对于网页是 URL，对于应用是路径
        let isWebLink: Bool
        let iconData: Data?  // 自定义图标数据
        let alias: String?  // 别名（用于显示）

        init(
            name: String, path: String, isWebLink: Bool, iconData: Data? = nil, alias: String? = nil
        ) {
            self.name = name
            self.path = path
            self.isWebLink = isWebLink
            self.iconData = iconData
            self.alias = alias
        }
    }

    /// 别名工具映射（alias -> AliasToolInfo）
    private var aliasToolMap: [String: AliasToolInfo] = [:]

    /// 设置别名映射表
    /// - Parameter map: 别名到路径的映射 (alias -> path)
    func setAliasMap(_ map: [String: String]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.aliasMap = map.reduce(into: [String: String]()) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }

            self.rebuildAliasTrie()

            print("MemoryIndex: Updated alias map with \(map.count) aliases")
        }
    }

    /// 设置别名映射表（带工具信息，支持网页直达等）
    /// - Parameter tools: 别名到工具信息的映射
    func setAliasMapWithTools(_ toolsMap: [String: AliasToolInfo]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.aliasToolMap = toolsMap.reduce(into: [String: AliasToolInfo]()) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }

            // 同时更新旧的 aliasMap 以保持兼容
            self.aliasMap = toolsMap.reduce(into: [String: String]()) { result, pair in
                result[pair.key.lowercased()] = pair.value.path
            }

            // 构建工具项目列表（用于名称搜索）
            self.tools.removeAll()
            var addedPaths = Set<String>()  // 避免重复添加
            for (_, toolInfo) in toolsMap {
                // 跳过已在 allItems 中的项目（如应用）
                if self.allItems[toolInfo.path] != nil { continue }
                // 跳过已添加的项目
                if addedPaths.contains(toolInfo.path) { continue }

                let item = SearchItem(
                    name: toolInfo.name,
                    path: toolInfo.path,
                    isWebLink: toolInfo.isWebLink,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias
                )
                self.tools.append(item)
                addedPaths.insert(toolInfo.path)
            }

            self.rebuildAliasTrie()

            print(
                "MemoryIndex: Updated alias map with \(toolsMap.count) aliases, \(self.tools.count) tool items"
            )
        }
    }

    /// 设置工具列表（用于名称搜索，不仅仅是别名）
    /// - Parameter toolsList: 工具信息列表
    func setToolsList(_ toolsList: [AliasToolInfo]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.tools.removeAll()
            var addedPaths = Set<String>()

            for toolInfo in toolsList {
                // 跳过已在 allItems 中的项目（如应用）
                if self.allItems[toolInfo.path] != nil { continue }
                // 跳过已添加的项目
                if addedPaths.contains(toolInfo.path) { continue }

                let item = SearchItem(
                    name: toolInfo.name,
                    path: toolInfo.path,
                    isWebLink: toolInfo.isWebLink,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias
                )
                self.tools.append(item)
                addedPaths.insert(toolInfo.path)
            }

            print("MemoryIndex: Updated tools list with \(self.tools.count) items")
        }
    }

    /// 重建别名 Trie
    private func rebuildAliasTrie() {
        aliasTrie = TrieNode()

        for (alias, path) in aliasMap {
            // 首先尝试从 allItems 中查找（应用类型）
            if let item = allItems[path] {
                insertIntoTrie(aliasTrie, key: alias, item: item)
            }
            // 如果找不到，尝试从 aliasToolMap 创建临时 SearchItem（网页直达等）
            else if let toolInfo = aliasToolMap[alias] {
                let item = SearchItem(
                    name: toolInfo.name,
                    path: toolInfo.path,
                    isWebLink: toolInfo.isWebLink,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias
                )
                insertIntoTrie(aliasTrie, key: alias, item: item)
            }
        }
    }

    /// 通过别名搜索（内部版本）
    /// - Parameter query: 搜索查询（小写）
    /// - Returns: 匹配的项目列表
    private func searchByAliasInternal(_ lowerQuery: String) -> [SearchItem] {
        var results: [SearchItem] = []

        // 精确匹配
        if let path = aliasMap[lowerQuery] {
            if let item = allItems[path] {
                results.append(item)
            } else if let toolInfo = aliasToolMap[lowerQuery] {
                // 为网页直达等创建临时 SearchItem
                let item = SearchItem(
                    name: toolInfo.name,
                    path: toolInfo.path,
                    isWebLink: toolInfo.isWebLink,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias
                )
                results.append(item)
            }
        }

        // 前缀匹配
        if let items = searchTrie(aliasTrie, prefix: lowerQuery) {
            for item in items {
                if !results.contains(where: { $0.path == item.path }) {
                    results.append(item)
                }
            }
        }

        return results
    }

    /// 通过别名搜索（公开版本）
    /// - Parameter query: 搜索查询
    /// - Returns: 匹配的项目列表
    func searchByAlias(_ query: String) -> [SearchItem] {
        let lowerQuery = query.lowercased()
        return searchByAliasInternal(lowerQuery)
    }
}
