import Cocoa
import Foundation

/// High-performance in-memory search index
/// - 前缀检索：名称/拼音有序数组 + 二分范围扫描，O(log n + 命中数)。
///   （替代旧 Trie——旧结构为换 O(1) 前缀检索在 key 经过的每个节点都存「全量路径 Set」，
///   60 万级索引需要数百万节点 × 每节点数百字节，内存 GB 级；有序数组每项只占 8 字节引用）
/// - contains 检索：bigram 倒排索引全量召回（替代只扫最近 200 个文件的线性扫描）
/// - 删除：主表即时过滤；前缀数组 / 倒排懒删除（候选验证时按身份过滤），定期紧凑重建
final class MemoryIndex {

    // MARK: - Data Structures

    /// Indexed search item (lightweight, stored in memory)
    final class SearchItem {
        let name: String
        let lowerName: String
        let path: String
        let lowerFileName: String
        let isApp: Bool
        let isDirectory: Bool
        let isWebLink: Bool  // 是否为网页直达
        let isUtility: Bool  // 是否为实用工具
        let isSystemCommand: Bool  // 是否为系统命令
        let supportsQuery: Bool  // 是否支持 query 扩展
        let defaultUrl: String?  // 默认 URL
        let modifiedDate: Date
        let pinyinFull: String?
        let pinyinAcronym: String?

        // English word acronym (e.g., "vsc" for "Visual Studio Code")
        let wordAcronym: String?

        // Lazy-loaded icon
        private var _icon: NSImage?
        /// 标记 _icon 是否在 init 中被显式设置（网页/工具/系统命令/iconData）。
        /// 这类图标释放后 getter 无法重建，因此 releaseLazyIcon 会跳过它们。
        private var hasCustomIcon: Bool = false

        var icon: NSImage {
            if _icon == nil {
                _icon = NSWorkspace.shared.icon(forFile: path)
                _icon?.size = NSSize(width: 32, height: 32)
            }
            return _icon ?? NSImage()
        }

        /// 释放文件/应用类懒加载的 NSWorkspace 图标，下次访问时重新加载（定期内存回收）。
        /// 自定义图标（网页/工具/系统命令/iconData）不受影响。
        func releaseLazyIcon() {
            guard !hasCustomIcon else { return }
            _icon = nil
        }

        /// 用于创建网页直达、实用工具、系统命令等非文件系统项目
        init(
            name: String, path: String, isWebLink: Bool, isUtility: Bool = false,
            isSystemCommand: Bool = false,
            iconData: Data? = nil, alias: String? = nil,
            supportsQuery: Bool = false, defaultUrl: String? = nil
        ) {
            self.name = name
            self.lowerName = name.lowercased()
            self.path = path
            self.lowerFileName = name.lowercased()

            // For local paths (aliases/tools), detect if it's an app or directory
            if !isWebLink && !isUtility && !isSystemCommand {
                // Remove trailing slash for reliable detection
                let cleanPath =
                    path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
                self.isApp = cleanPath.hasSuffix(".app")
                var isDir: ObjCBool = false
                self.isDirectory =
                    FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir)
                    && isDir.boolValue
            } else {
                self.isApp = false
                self.isDirectory = false
            }

            self.isWebLink = isWebLink
            self.isUtility = isUtility
            self.isSystemCommand = isSystemCommand
            self.supportsQuery = supportsQuery
            self.defaultUrl = defaultUrl
            self.modifiedDate = Date()
            self.wordAcronym = SearchItem.generateWordAcronym(from: name)
            self._displayAlias = alias
            // init 中显式设置的图标（iconData/systemSymbol 等）视为自定义图标，不可懒释放
            self.hasCustomIcon = (self._icon != nil)

            // 为中文名称生成拼音
            if name.utf8.count != name.count {
                self.pinyinFull = name.pinyin.lowercased().replacingOccurrences(of: " ", with: "")
                self.pinyinAcronym = name.pinyinAcronym.lowercased()
            } else {
                self.pinyinFull = nil
                self.pinyinAcronym = nil
            }

            // 设置图标：优先使用自定义图标
            if let data = iconData, let customIcon = NSImage(data: data) {
                customIcon.size = NSSize(width: 32, height: 32)
                self._icon = customIcon
            } else if isSystemCommand {
                // 系统命令：根据命令标识符使用对应的 SF Symbol 图标
                if let identifier = SystemCommandService.Identifier(rawValue: path) {
                    self._icon = NSImage(
                        systemSymbolName: identifier.iconName,
                        accessibilityDescription: "System Command")
                    self._icon?.size = NSSize(width: 32, height: 32)
                } else {
                    self._icon = NSImage(
                        systemSymbolName: "terminal", accessibilityDescription: "System Command")
                    self._icon?.size = NSSize(width: 32, height: 32)
                }
            } else if isWebLink {
                self._icon = NSImage(
                    systemSymbolName: "globe", accessibilityDescription: "Web Link")
                self._icon?.size = NSSize(width: 32, height: 32)
            } else if isUtility {
                self._icon = NSImage(
                    systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Utility")
                self._icon?.size = NSSize(width: 32, height: 32)
            }
        }

        init(from record: FileRecord) {
            self.name = record.name
            self.lowerName = record.name.lowercased()
            self.path = record.path
            self.lowerFileName = (record.path as NSString).lastPathComponent.lowercased()
            self.isApp = record.isApp
            self.isDirectory = record.isDirectory
            self.isWebLink = false  // 文件系统项目不是网页直达
            self.isUtility = false  // 文件系统项目不是实用工具
            self.isSystemCommand = false  // 文件系统项目不是系统命令
            self.supportsQuery = false
            self.defaultUrl = nil
            self.modifiedDate = record.modifiedDate ?? Date.distantPast
            self.pinyinFull = record.pinyinFull
            self.pinyinAcronym = record.pinyinAcronym
            self.wordAcronym = SearchItem.generateWordAcronym(from: record.name)
        }

        // 存储别名（用于显示）
        private var _displayAlias: String?
        var displayAlias: String? { _displayAlias }

        /// 设置显示别名
        func setDisplayAlias(_ alias: String?) {
            _displayAlias = alias
        }

        /// Generate acronym from first letter of each word
        /// "Visual Studio Code" -> "vsc", "Activity Monitor" -> "am"
        private static func generateWordAcronym(from name: String) -> String? {
            // 添加空字符串检查
            guard !name.isEmpty else { return nil }

            // Split by spaces, hyphens, underscores
            // 添加异常保护，防止在字符串处理时崩溃
            guard let characterSet = CharacterSet(charactersIn: " -_") as CharacterSet? else {
                return nil
            }

            let words = name.components(separatedBy: characterSet)
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
            case fuzzy = 3  // 子序列模糊匹配（非连续）
            case pinyin = 4

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

        /// 子序列模糊匹配打分（仅对 ASCII 查询有意义）。返回最高分或 nil。
        /// 用于 apps/tools「输错字母 / 缩写」也能命中的场景。
        func fuzzyMatchScore(_ lowerQuery: String) -> Int? {
            var best = 0
            var hit = false
            if let s = FuzzyMatcher.score(lowerQuery, in: lowerName), s > best {
                best = s
                hit = true
            }
            if let acronym = wordAcronym,
                let s = FuzzyMatcher.score(lowerQuery, in: acronym), s > best
            {
                best = s
                hit = true
            }
            return hit ? best : nil
        }

        /// 类型优先级（用于同层排序）
        /// 数值越小优先级越高
        var typePriority: Int {
            if isSystemCommand { return 0 }  // 系统命令最高
            if isUtility { return 1 }       // 实用工具
            if isApp { return 2 }           // 应用程序
            if isWebLink { return 3 }       // 网页直达
            if isDirectory { return 4 }     // 目录
            return 5                        // 普通文件最低
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
                isWebLink: isWebLink,
                isUtility: isUtility,
                isSystemCommand: isSystemCommand,
                supportsQueryExtension: supportsQuery,
                defaultUrl: defaultUrl
            )
        }
    }

    // MARK: - Properties

    private var apps: [SearchItem] = []
    private var files: [SearchItem] = []
    private var directories: [SearchItem] = []  // 单独存储目录，便于搜索
    private var tools: [SearchItem] = []  // 工具项目（网页直达等非文件系统项目）
    private var allItems: [String: SearchItem] = [:]  // path -> item for O(1) lookup

    // 前缀检索有序数组（按各自 key 升序，二分定位前缀范围）
    private var nameSorted: [SearchItem] = []  // 全部索引项，按 lowerName
    private var pinyinFullSorted: [SearchItem] = []  // 仅有拼音的项，按 pinyinFull
    private var pinyinAcronymSorted: [SearchItem] = []  // 仅有拼音的项，按 pinyinAcronym

    // bigram 倒排索引：名称相邻字符对 -> 文件/目录项，contains 全量召回
    private var bigramIndex: [String: [SearchItem]] = [:]

    // 懒删除累计的陈旧条目数（前缀数组/倒排中已移出 allItems 的引用），达阈值紧凑重建
    private var staleIndexEntries = 0

    // 别名支持
    private var aliasMap: [String: String] = [:]  // alias (lowercase) -> path

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
        var index = 0
        buildStreamed(
            chunkLoader: {
                guard index < records.count else { return nil }
                let end = min(index + 10_000, records.count)
                let chunk = Array(records[index..<end])
                index = end
                return chunk
            },
            completion: completion
        )
    }

    /// 流式构建索引：chunkLoader 在索引串行队列上被反复调用，返回 nil 表示结束。
    /// 启动加载时直接把数据库分批记录灌入，无需先物化全量 FileRecord 数组
    /// （60 万文件级别可减少一份数百 MB 的峰值内存，且少一次大数组拷贝）。
    func buildStreamed(
        chunkLoader: @escaping () -> [FileRecord]?,
        completion: (() -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let startTime = Date()

            // Clear existing index
            self.apps.removeAll()
            self.files.removeAll()
            self.directories.removeAll()
            self.allItems.removeAll()
            self.nameSorted.removeAll()
            self.pinyinFullSorted.removeAll()
            self.pinyinAcronymSorted.removeAll()
            self.bigramIndex.removeAll()
            self.staleIndexEntries = 0

            while let chunk = chunkLoader() {
                for record in chunk {
                    self.appendRecordLocked(record)
                }
            }

            self.finalizeBuildLocked(startTime: startTime)

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// 追加单条记录（必须在 queue 中调用，流式构建使用）
    private func appendRecordLocked(_ record: FileRecord) {
        let item = SearchItem(from: record)
        self.allItems[item.path] = item

        if item.isApp {
            self.apps.append(item)
        } else if item.isDirectory {
            self.directories.append(item)
        } else {
            self.files.append(item)
        }

        // 前缀有序数组与 bigram 倒排：构建期无序追加，finalize 时统一排序
        self.nameSorted.append(item)
        if item.pinyinFull != nil {
            self.pinyinFullSorted.append(item)
        }
        if item.pinyinAcronym != nil {
            self.pinyinAcronymSorted.append(item)
        }
        self.indexBigramsLocked(item)
    }

    /// 完成构建：排序与统计（必须在 queue 中调用）
    private func finalizeBuildLocked(startTime: Date) {
        // Sort apps by name length (shorter = more relevant)
        self.apps.sort { $0.name.count < $1.name.count }

        // Sort directories by modified date (recent first)
        self.directories.sort { $0.modifiedDate > $1.modifiedDate }

        // Sort files by modified date (recent first)
        self.files.sort { $0.modifiedDate > $1.modifiedDate }

        // 前缀检索数组排序（bigram 倒排在追加时已建好，无需处理）
        self.nameSorted.sort { $0.lowerName < $1.lowerName }
        self.pinyinFullSorted.sort { ($0.pinyinFull ?? "") < ($1.pinyinFull ?? "") }
        self.pinyinAcronymSorted.sort { ($0.pinyinAcronym ?? "") < ($1.pinyinAcronym ?? "") }

        // Update statistics
        self.appsCount = self.apps.count
        self.filesCount = self.files.count
        self.directoriesCount = self.directories.count
        self.totalCount = self.allItems.count

        let duration = Date().timeIntervalSince(startTime)
        print(
            "MemoryIndex: Built index with \(self.totalCount) items (\(self.appsCount) apps, \(self.directoriesCount) dirs, \(self.filesCount) files) in \(String(format: "%.3f", duration))s"
        )
    }

    /// 紧凑重建前缀有序数组与 bigram 倒排，回收懒删除残留的陈旧条目。
    /// 不动 allItems / apps / files / directories（它们是即时更新的）。
    /// 供 SearchEngine 定期调用做内存回收；顺带释放懒加载图标。
    func rebuildIndexes() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let start = Date()
            self.rebuildIndexesLocked(releaseIcons: true)
            print(
                "MemoryIndex: Indexes rebuilt (\(self.totalCount) items) in "
                + "\(String(format: "%.3f", Date().timeIntervalSince(start)))s [定期内存回收]"
            )
        }
    }

    /// 紧凑重建的实际逻辑（必须在 queue 中调用）。
    /// 大批量删除累计陈旧条目超阈值时也会走这里。
    private func rebuildIndexesLocked(releaseIcons: Bool) {
        nameSorted = allItems.values.sorted { $0.lowerName < $1.lowerName }
        pinyinFullSorted = allItems.values
            .filter { $0.pinyinFull != nil }
            .sorted { ($0.pinyinFull ?? "") < ($1.pinyinFull ?? "") }
        pinyinAcronymSorted = allItems.values
            .filter { $0.pinyinAcronym != nil }
            .sorted { ($0.pinyinAcronym ?? "") < ($1.pinyinAcronym ?? "") }

        bigramIndex.removeAll()
        for item in allItems.values {
            indexBigramsLocked(item)
            if releaseIcons {
                // 顺便释放文件/应用类懒加载的图标缓存（定期内存回收）
                item.releaseLazyIcon()
            }
        }
        staleIndexEntries = 0
    }

    /// Add a single item to index (用于实时更新)
    func add(_ record: FileRecord) {
        addBatch([record])
    }

    /// 批量添加（FSEvents 批处理路径）。
    /// 与逐条 add 相比：apps 只排序一次；files/directories 用归并保持 modifiedDate 降序，
    /// 避免逐条 insert(at: 0) 对 60 万级数组做 O(n) memmove（git checkout 场景会累积到秒级）。
    func addBatch(_ records: [FileRecord], completion: (() -> Void)? = nil) {
        guard !records.isEmpty else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }

            var newFiles: [SearchItem] = []
            var newDirectories: [SearchItem] = []
            var newItems: [SearchItem] = []  // 本次实际新增（用于归并进前缀有序数组）
            var addedApps = false

            for record in records {
                let item = SearchItem(from: record)

                // 检查是否已存在（调用方保证先删后加的顺序，这里兜底跳过）
                if self.allItems[item.path] != nil { continue }

                self.allItems[item.path] = item
                newItems.append(item)

                if item.isApp {
                    self.apps.append(item)
                    addedApps = true
                } else if item.isDirectory {
                    newDirectories.append(item)
                } else {
                    newFiles.append(item)
                }

                self.indexBigramsLocked(item)
            }

            if addedApps {
                self.apps.sort { $0.name.count < $1.name.count }
                self.appsCount = self.apps.count
            }
            if !newDirectories.isEmpty {
                self.directories = Self.mergeByDateDesc(self.directories, newDirectories)
                self.directoriesCount = self.directories.count
            }
            if !newFiles.isEmpty {
                self.files = Self.mergeByDateDesc(self.files, newFiles)
                self.filesCount = self.files.count
            }

            // 归并进前缀有序数组，保持二分检索要求的有序性
            if !newItems.isEmpty {
                self.nameSorted = Self.mergeSortedByKey(
                    self.nameSorted, newItems, key: { $0.lowerName })
                let newPinyinFull = newItems.filter { $0.pinyinFull != nil }
                if !newPinyinFull.isEmpty {
                    self.pinyinFullSorted = Self.mergeSortedByKey(
                        self.pinyinFullSorted, newPinyinFull, key: { $0.pinyinFull ?? "" })
                }
                let newAcronym = newItems.filter { $0.pinyinAcronym != nil }
                if !newAcronym.isEmpty {
                    self.pinyinAcronymSorted = Self.mergeSortedByKey(
                        self.pinyinAcronymSorted, newAcronym, key: { $0.pinyinAcronym ?? "" })
                }
            }

            self.totalCount = self.allItems.count

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// 合并两个按 modifiedDate 降序的数组（newItems 内部先排序），O(n+m)。
    private static func mergeByDateDesc(_ existing: [SearchItem], _ newItems: [SearchItem]) -> [SearchItem] {
        let sorted = newItems.sorted { $0.modifiedDate > $1.modifiedDate }

        var result: [SearchItem] = []
        result.reserveCapacity(existing.count + sorted.count)

        var i = 0
        var j = 0
        while i < existing.count && j < sorted.count {
            if existing[i].modifiedDate >= sorted[j].modifiedDate {
                result.append(existing[i])
                i += 1
            } else {
                result.append(sorted[j])
                j += 1
            }
        }
        result.append(contentsOf: existing[i...])
        result.append(contentsOf: sorted[j...])
        return result
    }

    /// 把新增条目按 key 归并进已升序数组（newItems 内部先排序），O(n+m)。
    /// 与 mergeByDateDesc 同思路：避免逐条二分插入对 60 万级数组做 O(n) memmove。
    private static func mergeSortedByKey(
        _ existing: [SearchItem],
        _ newItems: [SearchItem],
        key: (SearchItem) -> String
    ) -> [SearchItem] {
        let sorted = newItems.sorted { key($0) < key($1) }

        var result: [SearchItem] = []
        result.reserveCapacity(existing.count + sorted.count)

        var i = 0
        var j = 0
        while i < existing.count && j < sorted.count {
            if key(existing[i]) <= key(sorted[j]) {
                result.append(existing[i])
                i += 1
            } else {
                result.append(sorted[j])
                j += 1
            }
        }
        result.append(contentsOf: existing[i...])
        result.append(contentsOf: sorted[j...])
        return result
    }

    /// Remove an item from index
    func remove(path: String) {
        removeBatch(paths: [path])
    }

    /// 批量移除。对 apps/files/directories 各做一次遍历过滤，
    /// 替代逐条 remove 的 O(n) firstIndex 线性扫描（批量删除时是 O(n×m)）。
    func removeBatch(paths: [String], completion: (() -> Void)? = nil) {
        guard !paths.isEmpty else {
            completion.map { DispatchQueue.main.async(execute: $0) }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let removeSet = Set(paths)
            self.performRemovalLocked(
                items: removeSet.compactMap { self.allItems[$0] })
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// 移除路径本身及其全部子路径记录（目录删除的级联语义）。
    ///
    /// Finder「移到废纸篓」、目录重命名 / 移动时，FSEvents 只上报目录本身一条事件
    /// （子文件 inode 未变不会逐个上报），必须按前缀级联清理，否则子文件会永久残留在索引里。
    func removeSubtree(atPath path: String, completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }

            let prefix = path.hasSuffix("/") && path.count > 1
                ? String(path.dropLast()) + "/" : path + "/"

            var items: [SearchItem] = []
            if let item = self.allItems[path] {
                items.append(item)
            }
            for (key, item) in self.allItems where key.hasPrefix(prefix) {
                items.append(item)
            }

            self.performRemovalLocked(items: items)

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// 实际执行移除（必须在 queue 中调用）。
    /// 主表（allItems/apps/files/directories）即时过滤；
    /// 前缀有序数组与 bigram 倒排采用懒删除——先保留陈旧引用，
    /// 检索时用 allItems 身份校验过滤，累计超阈值再整体紧凑重建。
    /// （旧 Trie 需逐条修剪节点避免只增不减，曾导致 6 天累积 30+GB；现在删除是 O(1)）
    private func performRemovalLocked(items: [SearchItem]) {
        guard !items.isEmpty else { return }

        let removeSet = Set(items.map { $0.path })
        for path in removeSet {
            allItems.removeValue(forKey: path)
        }

        // 单次遍历过滤，替代逐条 firstIndex
        apps.removeAll { removeSet.contains($0.path) }
        directories.removeAll { removeSet.contains($0.path) }
        files.removeAll { removeSet.contains($0.path) }

        staleIndexEntries += items.count
        if staleIndexEntries > 50_000 {
            rebuildIndexesLocked(releaseIcons: false)
        }

        appsCount = apps.count
        filesCount = files.count
        directoriesCount = directories.count
        totalCount = allItems.count
    }

    /// 当前索引的全部路径快照（用于后台存在性审计）。
    /// 字符串是 CoW，仅复制指针，60 万级也只有几 MB。
    func allIndexedPaths() -> [String] {
        return queue.sync { Array(allItems.keys) }
    }

    // MARK: - Search

    /// Optimized synchronous search - sub-5ms for 600k files
    /// 高性能搜索：有序数组二分前缀检索 + bigram 倒排 contains 全量召回
    func search(
        query: String,
        excludedApps: Set<String> = [],
        excludedPaths: [String] = [],
        excludedExtensions: Set<String> = [],
        excludedFolderNames: Set<String> = [],
        maxResults: Int = 30
    ) -> [SearchItem] {
        guard !query.isEmpty else { return [] }

        // 通过串行队列保证线程安全，与 add()/remove() 的写操作同步
        return queue.sync {
            searchInternal(
                query: query,
                excludedApps: excludedApps,
                excludedPaths: excludedPaths,
                excludedExtensions: excludedExtensions,
                excludedFolderNames: excludedFolderNames,
                maxResults: maxResults
            )
        }
    }

    /// 内部搜索实现（必须在 queue 中调用）
    private func searchInternal(
        query: String,
        excludedApps: Set<String>,
        excludedPaths: [String],
        excludedExtensions: Set<String>,
        excludedFolderNames: Set<String>,
        maxResults: Int
    ) -> [SearchItem] {

        let lowerQuery = query.lowercased()
        let queryIsAscii = query.allSatisfy { $0.isASCII }

        // Pre-allocate results with capacity to avoid reallocations
        var results: [SearchItem] = []
        results.reserveCapacity(maxResults)

        // Use Set for O(1) deduplication instead of array operations
        var seenPaths = Set<String>(minimumCapacity: maxResults)

        // 1. Fast path: Alias search (highest priority, O(1) lookup)
        let aliasResults = searchByAliasInternal(lowerQuery)
        for item in aliasResults {
            if results.count >= maxResults { break }
            if excludedApps.contains(item.path) { continue }
            if seenPaths.insert(item.path).inserted {
                results.append(item)
            }
        }

        if results.count >= maxResults {
            return Array(results.prefix(maxResults))
        }

        // 2. 前缀检索：有序数组二分定位前缀范围（name + pinyin），O(log n + 命中数)
        var prefixMatches: [SearchItem] = []
        prefixMatches.reserveCapacity(maxResults)

        collectPrefixMatches(
            from: nameSorted, key: { $0.lowerName },
            lowerQuery: lowerQuery, queryIsAscii: queryIsAscii,
            excludedApps: excludedApps, excludedPaths: excludedPaths,
            excludedExtensions: excludedExtensions, excludedFolderNames: excludedFolderNames,
            into: &prefixMatches, seenPaths: &seenPaths)

        // 拼音前缀仅对 ASCII 查询有意义（拼音 key 本身是 ASCII）
        if queryIsAscii {
            collectPrefixMatches(
                from: pinyinFullSorted, key: { $0.pinyinFull ?? "" },
                lowerQuery: lowerQuery, queryIsAscii: queryIsAscii,
                excludedApps: excludedApps, excludedPaths: excludedPaths,
                excludedExtensions: excludedExtensions, excludedFolderNames: excludedFolderNames,
                into: &prefixMatches, seenPaths: &seenPaths)
            collectPrefixMatches(
                from: pinyinAcronymSorted, key: { $0.pinyinAcronym ?? "" },
                lowerQuery: lowerQuery, queryIsAscii: queryIsAscii,
                excludedApps: excludedApps, excludedPaths: excludedPaths,
                excludedExtensions: excludedExtensions, excludedFolderNames: excludedFolderNames,
                into: &prefixMatches, seenPaths: &seenPaths)
        }

        // 按类型优先级排序：系统命令 > 实用工具 > 应用 > 网页直达 > 目录 > 文件
        prefixMatches.sort { $0.typePriority < $1.typePriority }

        // 加入结果
        for item in prefixMatches {
            guard results.count < maxResults else { break }
            if seenPaths.insert(item.path).inserted {
                results.append(item)
            }
        }

        if results.count >= maxResults {
            return Array(results.prefix(maxResults))
        }

        // 3. Targeted linear search only for high-value items
        // Search apps and tools first (small datasets, high value)
        searchHighValueItems(
            lowerQuery: lowerQuery,
            queryIsAscii: queryIsAscii,
            excludedApps: excludedApps,
            excludedPaths: excludedPaths,
            excludedExtensions: excludedExtensions,
            excludedFolderNames: excludedFolderNames,
            results: &results,
            seenPaths: &seenPaths,
            maxResults: maxResults
        )

        if results.count >= maxResults {
            return Array(results.prefix(maxResults))
        }

        // 4. contains 检索（中缀匹配，如 "report" 匹配 "my_report_final"）
        if lowerQuery.count > 1 {
            // bigram 倒排：全量召回文件 + 目录的中缀匹配。
            // 旧实现只线性扫最近 50 目录 / 200 文件，老文件的中缀匹配永远搜不到。
            searchByBigramContains(
                lowerQuery: lowerQuery,
                queryIsAscii: queryIsAscii,
                excludedPaths: excludedPaths,
                excludedExtensions: excludedExtensions,
                excludedFolderNames: excludedFolderNames,
                results: &results,
                seenPaths: &seenPaths,
                maxResults: maxResults
            )
        } else {
            // 单字符查询没有 bigram，退回旧的线性扫描（最近目录 / 文件）
            searchDirectories(
                lowerQuery: lowerQuery,
                queryIsAscii: queryIsAscii,
                excludedPaths: excludedPaths,
                excludedFolderNames: excludedFolderNames,
                results: &results,
                seenPaths: &seenPaths,
                maxResults: maxResults
            )

            if results.count >= maxResults {
                return Array(results.prefix(maxResults))
            }

            searchFiles(
                lowerQuery: lowerQuery,
                queryIsAscii: queryIsAscii,
                excludedPaths: excludedPaths,
                excludedExtensions: excludedExtensions,
                excludedFolderNames: excludedFolderNames,
                results: &results,
                seenPaths: &seenPaths,
                maxResults: maxResults
            )
        }

        // 最终排序：matchType > typePriority > 原始顺序（稳定排序保持层间优先级）
        let finalResults = Array(results.prefix(maxResults))
        return finalResults.enumerated().map { (index, item) -> (Int, SearchItem, SearchItem.MatchType) in
            let matchType: SearchItem.MatchType
            if let mt = item.matchesQuery(lowerQuery) {
                matchType = mt
            } else if queryIsAscii && item.fuzzyMatchScore(lowerQuery) != nil {
                matchType = .fuzzy
            } else {
                matchType = .pinyin
            }
            return (index, item, matchType)
        }.sorted { a, b in
            // 先按匹配类型排序
            if a.2 != b.2 { return a.2 < b.2 }
            // 同匹配类型按类型优先级排序
            if a.1.typePriority != b.1.typePriority { return a.1.typePriority < b.1.typePriority }
            // 同类型保持原始顺序
            return a.0 < b.0
        }.map { $0.1 }
    }

    // MARK: - Optimized Search Helpers

    private func searchHighValueItems(
        lowerQuery: String,
        queryIsAscii: Bool,
        excludedApps: Set<String>,
        excludedPaths: [String],
        excludedExtensions: Set<String>,
        excludedFolderNames: Set<String>,
        results: inout [SearchItem],
        seenPaths: inout Set<String>,
        maxResults: Int
    ) {
        // Search apps and tools (small datasets, high priority)
        // 分两个循环遍历，避免每次按键都拼接新数组
        let currentApps = apps
        let currentTools = tools

        for item in currentApps {
            guard results.count < maxResults else { break }
            guard seenPaths.insert(item.path).inserted else { continue }
            guard !excludedApps.contains(item.path) else { continue }

            if item.matchesQuery(lowerQuery) != nil {
                results.append(item)
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                results.append(item)
            } else if queryIsAscii && item.fuzzyMatchScore(lowerQuery) != nil {
                // 子序列模糊匹配：输错字母 / 缩写也能命中（仅 apps/tools）
                results.append(item)
            }
        }

        for item in currentTools {
            guard results.count < maxResults else { break }
            guard seenPaths.insert(item.path).inserted else { continue }
            guard !excludedApps.contains(item.path) else { continue }

            if item.matchesQuery(lowerQuery) != nil {
                results.append(item)
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                results.append(item)
            } else if queryIsAscii && item.fuzzyMatchScore(lowerQuery) != nil {
                results.append(item)
            }
        }
    }

    /// 线性扫描最近目录（仅单字符查询的回退路径；≥2 字符走 bigram 倒排全量召回）
    private func searchDirectories(
        lowerQuery: String,
        queryIsAscii: Bool,
        excludedPaths: [String],
        excludedFolderNames: Set<String>,
        results: inout [SearchItem],
        seenPaths: inout Set<String>,
        maxResults: Int
    ) {
        let currentDirs = directories
        // Limit directory search to most recent 50
        for item in currentDirs.prefix(50) {
            guard results.count < maxResults else { break }
            guard seenPaths.insert(item.path).inserted else { continue }

            // Apply exclusions
            if excludedPaths.contains(where: { item.path.hasPrefix($0) }) { continue }
            if !excludedFolderNames.isEmpty {
                let components = item.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            if item.matchesQuery(lowerQuery) != nil {
                results.append(item)
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                results.append(item)
            }
        }
    }

    /// 线性扫描最近文件（仅单字符查询的回退路径；≥2 字符走 bigram 倒排全量召回）
    private func searchFiles(
        lowerQuery: String,
        queryIsAscii: Bool,
        excludedPaths: [String],
        excludedExtensions: Set<String>,
        excludedFolderNames: Set<String>,
        results: inout [SearchItem],
        seenPaths: inout Set<String>,
        maxResults: Int
    ) {
        let currentFiles = files
        // DRASTICALLY reduce file scan from 5000 to 200 for 600k files
        let maxFileScan = min(200, currentFiles.count)

        for item in currentFiles.prefix(maxFileScan) {
            guard results.count < maxResults else { break }
            guard seenPaths.insert(item.path).inserted else { continue }

            // Apply exclusions
            if excludedPaths.contains(where: { item.path.hasPrefix($0) }) { continue }
            if !excludedExtensions.isEmpty {
                let ext = (item.path as NSString).pathExtension.lowercased()
                if excludedExtensions.contains(ext) { continue }
            }
            if !excludedFolderNames.isEmpty {
                let components = item.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            if item.matchesQuery(lowerQuery) != nil {
                results.append(item)
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                results.append(item)
            }
        }
    }

    // MARK: - 前缀检索（有序数组 + 二分）

    /// 二分查找：返回第一个 key >= target 的下标（数组需按 key 升序）。
    /// 前缀范围 = [lowerBound(prefix), 向后扫描到前缀失配)。
    private static func lowerBound(
        _ array: [SearchItem], key: (SearchItem) -> String, target: String
    ) -> Int {
        var low = 0
        var high = array.count
        while low < high {
            let mid = (low + high) / 2
            if key(array[mid]) < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 在按键升序的数组中做前缀范围检索，收集匹配项到 matches。
    /// 单个数组最多收集 maxPrefixCandidates 条，避免超短查询（如单字母）
    /// 的前缀范围过大导致长尾扫描。
    private func collectPrefixMatches(
        from sortedItems: [SearchItem],
        key: (SearchItem) -> String,
        lowerQuery: String,
        queryIsAscii: Bool,
        excludedApps: Set<String>,
        excludedPaths: [String],
        excludedExtensions: Set<String>,
        excludedFolderNames: Set<String>,
        into matches: inout [SearchItem],
        seenPaths: inout Set<String>
    ) {
        var collected = 0
        var index = Self.lowerBound(sortedItems, key: key, target: lowerQuery)
        while index < sortedItems.count {
            let item = sortedItems[index]
            guard key(item).hasPrefix(lowerQuery) else { break }
            index += 1

            // 懒删除校验：条目可能已移出 allItems（或同路径被新对象替换）
            guard allItems[item.path] === item else { continue }
            guard !seenPaths.contains(item.path) else { continue }

            // Apply exclusions early to avoid unnecessary processing
            guard !excludedApps.contains(item.path) else { continue }
            if excludedPaths.contains(where: { item.path.hasPrefix($0) }) { continue }

            if !excludedExtensions.isEmpty {
                let ext = (item.path as NSString).pathExtension.lowercased()
                if excludedExtensions.contains(ext) { continue }
            }

            if !excludedFolderNames.isEmpty {
                let components = item.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            // Check actual match
            if item.matchesQuery(lowerQuery) != nil {
                matches.append(item)
                collected += 1
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                matches.append(item)
                collected += 1
            }

            if collected >= Self.maxPrefixCandidates { break }
        }
    }

    /// 单个前缀数组最多收集的候选数（超短查询的防御性上限）
    private static let maxPrefixCandidates = 2_000

    // MARK: - bigram 倒排索引（contains 全量召回）

    /// 提取字符串的相邻字符对（去重）。少于 2 个字符返回空数组。
    private static func bigrams(of key: String) -> [String] {
        guard key.count > 1 else { return [] }
        let chars = Array(key)
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(chars.count - 1, 32))
        for i in 0..<(chars.count - 1) {
            let gram = String(chars[i...i + 1])
            if seen.insert(gram).inserted {
                result.append(gram)
            }
        }
        return result
    }

    /// 把条目名称的 bigram 写入倒排索引（必须在 queue 中调用）。
    /// apps 不入倒排：数量少（几百个）且步骤 3 已全量线性扫描 + 模糊匹配。
    private func indexBigramsLocked(_ item: SearchItem) {
        guard !item.isApp else { return }
        for gram in Self.bigrams(of: item.lowerName) {
            bigramIndex[gram, default: []].append(item)
        }
    }

    /// 用 bigram 倒排做全量 contains 检索（文件 + 目录）。
    /// 取「查询 bigram 中 posting 最短」的列表逐项验证完整 contains——
    /// 名字包含查询就必须包含查询的每个 bigram，因此任一 bigram 在索引中
    /// 不存在即可直接判定零命中（字典 miss 即 O(1) 出口）。
    private func searchByBigramContains(
        lowerQuery: String,
        queryIsAscii: Bool,
        excludedPaths: [String],
        excludedExtensions: Set<String>,
        excludedFolderNames: Set<String>,
        results: inout [SearchItem],
        seenPaths: inout Set<String>,
        maxResults: Int
    ) {
        var shortestPostings: [SearchItem] = []
        var shortestCount = Int.max
        for gram in Self.bigrams(of: lowerQuery) {
            guard let postings = bigramIndex[gram] else { return }
            if postings.count < shortestCount {
                shortestCount = postings.count
                shortestPostings = postings
            }
        }
        guard !shortestPostings.isEmpty else { return }

        for item in shortestPostings {
            guard results.count < maxResults else { break }

            // 懒删除校验：posting 里可能残留已移除的条目
            guard allItems[item.path] === item else { continue }
            guard seenPaths.insert(item.path).inserted else { continue }

            // Apply exclusions
            if excludedPaths.contains(where: { item.path.hasPrefix($0) }) { continue }
            if !excludedExtensions.isEmpty {
                let ext = (item.path as NSString).pathExtension.lowercased()
                if excludedExtensions.contains(ext) { continue }
            }
            if !excludedFolderNames.isEmpty {
                let components = item.path.components(separatedBy: "/")
                if !excludedFolderNames.isDisjoint(with: components) { continue }
            }

            // 前缀命中已在步骤 2 进入 seenPaths，这里自然只收中缀（contains）匹配
            if item.matchesQuery(lowerQuery) != nil {
                results.append(item)
            } else if queryIsAscii && item.matchesPinyin(lowerQuery) {
                results.append(item)
            }
        }
    }

    // MARK: - 别名支持

    /// 别名工具信息（用于非应用类型的工具）
    struct AliasToolInfo {
        let name: String
        let path: String  // 对于网页是 URL，对于应用是路径，对于系统命令是命令标识符
        let isWebLink: Bool
        let isUtility: Bool  // 是否为实用工具
        let isSystemCommand: Bool  // 是否为系统命令
        let iconData: Data?  // 自定义图标数据
        let alias: String?  // 别名（用于显示）
        let supportsQuery: Bool  // 是否支持 query 扩展
        let defaultUrl: String?  // 默认 URL

        init(
            name: String, path: String, isWebLink: Bool, isUtility: Bool = false,
            isSystemCommand: Bool = false,
            iconData: Data? = nil, alias: String? = nil,
            supportsQuery: Bool = false, defaultUrl: String? = nil
        ) {
            self.name = name
            self.path = path
            self.isWebLink = isWebLink
            self.isUtility = isUtility
            self.isSystemCommand = isSystemCommand
            self.iconData = iconData
            self.alias = alias
            self.supportsQuery = supportsQuery
            self.defaultUrl = defaultUrl
        }
    }

    /// 别名工具映射（alias -> AliasToolInfo）
    private var aliasToolMap: [String: AliasToolInfo] = [:]

    /// 设置别名映射表
    /// - Parameter map: 别名到路径的映射 (alias -> path)
    func setAliasMap(_ map: [String: String]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 清除旧的所有显示别名，确保更改立即生效
            for item in self.allItems.values {
                item.setDisplayAlias(nil)
            }

            self.aliasMap = map.reduce(into: [String: String]()) { result, pair in
                result[pair.key.lowercased()] = pair.value
            }

            print("MemoryIndex: Updated alias map with \(map.count) aliases")
        }
    }

    /// 设置别名映射表（带工具信息，支持网页直达等）
    /// - Parameter tools: 别名到工具信息的映射
    func setAliasMapWithTools(_ toolsMap: [String: AliasToolInfo]) {
        queue.async { [weak self] in
            guard let self = self else { return }

            // 清除旧的所有显示别名，确保更改立即生效
            for item in self.allItems.values {
                item.setDisplayAlias(nil)
            }

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
                    isUtility: toolInfo.isUtility,
                    isSystemCommand: toolInfo.isSystemCommand,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias,
                    supportsQuery: toolInfo.supportsQuery,
                    defaultUrl: toolInfo.defaultUrl
                )
                self.tools.append(item)
                addedPaths.insert(toolInfo.path)
            }

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
                    isUtility: toolInfo.isUtility,
                    isSystemCommand: toolInfo.isSystemCommand,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias,
                    supportsQuery: toolInfo.supportsQuery,
                    defaultUrl: toolInfo.defaultUrl
                )
                self.tools.append(item)
                addedPaths.insert(toolInfo.path)
            }

            print("MemoryIndex: Updated tools list with \(self.tools.count) items")
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
                // 为文件系统项目设置显示别名
                item.setDisplayAlias(lowerQuery)
                results.append(item)
            } else if let toolInfo = aliasToolMap[lowerQuery] {
                // 为网页直达、系统命令等创建临时 SearchItem
                let item = SearchItem(
                    name: toolInfo.name,
                    path: toolInfo.path,
                    isWebLink: toolInfo.isWebLink,
                    isUtility: toolInfo.isUtility,
                    isSystemCommand: toolInfo.isSystemCommand,
                    iconData: toolInfo.iconData,
                    alias: toolInfo.alias,
                    supportsQuery: toolInfo.supportsQuery,
                    defaultUrl: toolInfo.defaultUrl
                )
                results.append(item)
            }
        }

        // 前缀匹配 - 查找所有匹配的别名并设置
        for (alias, path) in aliasMap where alias.hasPrefix(lowerQuery) && alias != lowerQuery {
            if let item = allItems[path] {
                if !results.contains(where: { $0.path == item.path }) {
                    item.setDisplayAlias(alias)
                    results.append(item)
                }
            } else if let toolInfo = aliasToolMap[alias] {
                if !results.contains(where: { $0.path == toolInfo.path }) {
                    let item = SearchItem(
                        name: toolInfo.name,
                        path: toolInfo.path,
                        isWebLink: toolInfo.isWebLink,
                        isUtility: toolInfo.isUtility,
                        isSystemCommand: toolInfo.isSystemCommand,
                        iconData: toolInfo.iconData,
                        alias: toolInfo.alias,
                        supportsQuery: toolInfo.supportsQuery,
                        defaultUrl: toolInfo.defaultUrl
                    )
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
        return queue.sync {
            searchByAliasInternal(lowerQuery)
        }
    }
}
