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
            self.modifiedDate = record.modifiedDate ?? Date.distantPast
            self.pinyinFull = record.pinyinFull
            self.pinyinAcronym = record.pinyinAcronym

            // Generate word acronym for multi-word names (e.g., "Visual Studio Code" -> "vsc")
            self.wordAcronym = SearchItem.generateWordAcronym(from: record.name)
        }

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
                isDirectory: isDirectory
            )
        }
    }

    // MARK: - Properties

    private var apps: [SearchItem] = []
    private var files: [SearchItem] = []
    private var directories: [SearchItem] = []  // 单独存储目录，便于搜索
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
        let aliasResults = searchByAliasInternal(lowerQuery)
        for item in aliasResults {
            if excludedApps.contains(item.path) { continue }
            aliasMatched.insert(item.path)

            if item.isApp {
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

        // Sort apps
        matchedApps.sort { lhs, rhs in
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

    /// 重建别名 Trie
    private func rebuildAliasTrie() {
        aliasTrie = TrieNode()

        for (alias, path) in aliasMap {
            if let item = allItems[path] {
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
        if let path = aliasMap[lowerQuery], let item = allItems[path] {
            results.append(item)
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
