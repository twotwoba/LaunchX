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
    private var allItems: [String: SearchItem] = [:]  // path -> item for O(1) lookup

    private var nameTrie = TrieNode()
    private var pinyinTrie = TrieNode()

    private let indexQueue = DispatchQueue(label: "com.launchx.memoryindex", qos: .userInteractive)

    // Statistics
    private(set) var appsCount: Int = 0
    private(set) var filesCount: Int = 0
    private(set) var totalCount: Int = 0

    // MARK: - Building Index

    /// Build index from database records
    func build(from records: [FileRecord], completion: (() -> Void)? = nil) {
        indexQueue.async { [weak self] in
            guard let self = self else { return }

            let startTime = Date()

            // Clear existing index
            self.apps.removeAll()
            self.files.removeAll()
            self.allItems.removeAll()
            self.nameTrie = TrieNode()
            self.pinyinTrie = TrieNode()

            // Reserve capacity
            self.apps.reserveCapacity(500)
            self.files.reserveCapacity(records.count)
            self.allItems.reserveCapacity(records.count)

            // Build items
            for record in records {
                let item = SearchItem(from: record)
                self.allItems[item.path] = item

                if item.isApp {
                    self.apps.append(item)
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

            // Sort files by modified date (recent first)
            self.files.sort { $0.modifiedDate > $1.modifiedDate }

            // Update statistics
            self.appsCount = self.apps.count
            self.filesCount = self.files.count
            self.totalCount = self.allItems.count

            let duration = Date().timeIntervalSince(startTime)
            print(
                "MemoryIndex: Built index with \(self.totalCount) items in \(String(format: "%.3f", duration))s"
            )

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// Add a single item to index
    func add(_ record: FileRecord) {
        indexQueue.async { [weak self] in
            guard let self = self else { return }

            let item = SearchItem(from: record)
            self.allItems[item.path] = item

            if item.isApp {
                self.apps.append(item)
                self.apps.sort { $0.name.count < $1.name.count }
                self.appsCount = self.apps.count
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
        indexQueue.async { [weak self] in
            guard let self = self, let item = self.allItems[path] else { return }

            self.allItems.removeValue(forKey: path)

            if item.isApp {
                self.apps.removeAll { $0.path == path }
                self.appsCount = self.apps.count
            } else {
                self.files.removeAll { $0.path == path }
                self.filesCount = self.files.count
            }

            // Note: Removing from Trie is complex, we skip it for now
            // The item will just be filtered out during search

            self.totalCount = self.allItems.count
        }
    }

    // MARK: - Search

    /// Synchronous search - must be extremely fast (< 5ms)
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
        var matchedFiles: [(item: SearchItem, matchType: SearchItem.MatchType)] = []

        matchedApps.reserveCapacity(10)
        matchedFiles.reserveCapacity(20)

        // 1. Search Apps (fast, small list)
        for app in apps {
            if excludedApps.contains(app.path) { continue }

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

        // 2. Search Files (limit iterations)
        let maxFileIterations = min(files.count, 5000)

        for i in 0..<maxFileIterations {
            let file = files[i]

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
                if matchedFiles.count >= 20 { break }
                continue
            }

            if queryIsAscii && file.matchesPinyin(lowerQuery) {
                matchedFiles.append((file, .pinyin))
                if matchedFiles.count >= 20 { break }
            }
        }

        // Sort files
        matchedFiles.sort { lhs, rhs in
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.modifiedDate > rhs.item.modifiedDate
        }

        // Combine results
        let topApps = matchedApps.prefix(10).map { $0.item }
        let topFiles = matchedFiles.prefix(20).map { $0.item }

        return Array(topApps) + Array(topFiles)
    }

    /// Search using Trie for prefix matching (even faster for prefix queries)
    func searchWithTrie(query: String, maxResults: Int = 30) -> [SearchItem] {
        guard !query.isEmpty else { return [] }

        let lowerQuery = query.lowercased()
        var results: [SearchItem] = []

        // Search name trie
        if let items = searchTrie(nameTrie, prefix: lowerQuery) {
            results.append(contentsOf: items)
        }

        // Search pinyin trie if query is ASCII
        if query.allSatisfy({ $0.isASCII }) {
            if let items = searchTrie(pinyinTrie, prefix: lowerQuery) {
                results.append(contentsOf: items)
            }
        }

        // Deduplicate and sort
        var seen = Set<String>()
        results = results.filter { seen.insert($0.path).inserted }

        // Sort: apps first, then by name length
        results.sort { lhs, rhs in
            if lhs.isApp != rhs.isApp {
                return lhs.isApp
            }
            return lhs.name.count < rhs.name.count
        }

        return Array(results.prefix(maxResults))
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
}
