import Cocoa
import Combine
import Foundation

/// Main search engine that coordinates all components
/// Replaces NSMetadataQuery-based search with custom implementation
final class SearchEngine: ObservableObject {
    static let shared = SearchEngine()

    // MARK: - Published State (MainActor)

    @MainActor @Published private(set) var isIndexing = false
    @MainActor @Published private(set) var indexProgress: (count: Int, path: String) = (0, "")
    @MainActor @Published private(set) var isReady = false

    // Statistics
    @MainActor @Published private(set) var appsCount: Int = 0
    @MainActor @Published private(set) var filesCount: Int = 0
    @MainActor @Published private(set) var totalCount: Int = 0
    @MainActor @Published private(set) var indexingDuration: TimeInterval = 0
    @MainActor @Published private(set) var lastIndexTime: Date?

    // MARK: - Components

    private let database = IndexDatabase.shared
    private let indexer = FileIndexer()
    private let memoryIndex = MemoryIndex()
    private let fsMonitor = FSEventsMonitor()
    private let searchCache = SearchCache()
    private let performanceMonitor = SearchPerformanceMonitor.shared

    // MARK: - Thread-safe Configuration

    private let configLock = NSLock()
    private var _searchConfig: SearchConfig = SearchConfig.load()

    private var searchConfig: SearchConfig {
        get {
            configLock.lock()
            defer { configLock.unlock() }
            return _searchConfig
        }
        set {
            configLock.lock()
            _searchConfig = newValue
            configLock.unlock()
        }
    }

    // 缓存各功能 Settings，避免每次按键都反序列化（UserDefaults + JSONDecoder）
    private(set) var cachedBookmarkSettings: BookmarkSettings = BookmarkSettings.load()
    private(set) var cachedTwoFactorAuthSettings = TwoFactorAuthSettings.load()
    private(set) var cachedClaudeCodeSettings = ClaudeCodeSwitcherSettings.load()
    private(set) var cachedCodexSettings = CodexSwitcherSettings.load()
    private(set) var cachedStockSettings = StockSettings.load()

    // 缓存默认搜索网页直达结果
    private var cachedDefaultSearchWebLinks: [SearchResult]?

    private var configObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var customItemsConfigObserver: NSObjectProtocol?
    private var toolsConfigObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?

    // FSEvents 批量处理（磁盘写入优化）
    private var fsEventQueue: [FSEventsMonitor.FSEvent] = []
    private var fsEventTimer: Timer?

    // WAL checkpoint 定时器（磁盘写入优化）
    private var walCheckpointTimer: Timer?

    // Trie 定期重建（内存回收：Trie 只增不减，定期全量重建回收死节点，曾导致 30+GB 膨胀）
    private var trieRebuildTimer: Timer?
    private let trieRebuildInterval: TimeInterval = 6 * 3600  // 每 6 小时

    // 失效条目审计（清理 App 未运行期间删除等 FSEvents 覆盖不到的死链）
    private var staleAuditScheduled = false

    // FSEvents 批量处理开关（可通过配置控制）
    private var fsEventsBatchProcessingEnabled: Bool {
        DiskWriteOptimizationSettings.shared.fsEventsBatchProcessingEnabled
    }

    // MARK: - Initialization

    private init() {
        setupConfigObserver()
        setupCustomItemsConfigObserver()
        setupSettingsObserver()
        loadIndexOnStartup()
        startWALCheckpointTimer()
        startTrieRebuildTimer()
    }

    /// 监听 UserDefaults 变化，刷新缓存的 Settings
    private func setupSettingsObserver() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 刷新所有缓存的 Settings，确保配置变更立即生效
            self?.cachedBookmarkSettings = BookmarkSettings.load()
            self?.cachedTwoFactorAuthSettings = TwoFactorAuthSettings.load()
            self?.cachedClaudeCodeSettings = ClaudeCodeSwitcherSettings.load()
            self?.cachedCodexSettings = CodexSwitcherSettings.load()
            self?.cachedStockSettings = StockSettings.load()
            self?.cachedDefaultSearchWebLinks = nil  // 清除缓存，下次搜索时重新生成
        }
    }

    private func setupConfigObserver() {
        // Listen for config updates (no reindex needed)
        configObserver = NotificationCenter.default.addObserver(
            forName: .searchConfigDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let config = notification.object as? SearchConfig {
                self?.searchConfig = config
            }
        }

        // Listen for config changes that need reindex
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .searchConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }

            if let newConfig = notification.object as? SearchConfig {
                // 更新当前配置
                self.searchConfig = newConfig

                Task { @MainActor [weak self] in
                    self?.rebuildIndex()
                }
            }
        }
    }

    /// 监听自定义项目配置变化（别名更新）
    private func setupCustomItemsConfigObserver() {
        // 监听旧的 CustomItemsConfig 变化（向后兼容）
        customItemsConfigObserver = NotificationCenter.default.addObserver(
            forName: .customItemsConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadAliasMap()
        }

        // 监听新的 ToolsConfig 变化
        toolsConfigObserver = NotificationCenter.default.addObserver(
            forName: .toolsConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadAliasMap()
        }

        // 初始加载别名
        loadAliasMap()
    }

    /// 加载别名映射到内存索引
    private func loadAliasMap() {
        // 配置发生变化时，清除搜索缓存，确保别名和启用状态立即生效
        searchCache.clear()
        cachedDefaultSearchWebLinks = nil  // 清除默认搜索链接缓存

        // 优先使用新的 ToolsConfig
        let toolsConfig = ToolsConfig.load()
        if !toolsConfig.tools.isEmpty {
            // 构建带工具信息的别名映射（仅有别名的工具）
            var aliasTools: [String: MemoryIndex.AliasToolInfo] = [:]
            // 构建所有工具列表（用于名称搜索，包括没有别名的）
            var allToolsList: [MemoryIndex.AliasToolInfo] = []

            for tool in toolsConfig.enabledTools {
                let hasAlias = tool.alias != nil && !tool.alias!.isEmpty

                switch tool.type {
                case .app:
                    if let path = tool.path {
                        let info = MemoryIndex.AliasToolInfo(
                            name: tool.name,
                            path: path,
                            isWebLink: false,
                            isUtility: false,
                            iconData: nil,
                            alias: tool.alias,
                            supportsQuery: false,
                            defaultUrl: nil
                        )
                        if hasAlias {
                            aliasTools[tool.alias!] = info
                        }
                        // 加入 allToolsList 以确保即使目录被移除，核心应用依然可以被搜索到
                        allToolsList.append(info)
                    }
                case .webLink:
                    if let url = tool.url {
                        let info = MemoryIndex.AliasToolInfo(
                            name: tool.name,
                            path: url,
                            isWebLink: true,
                            isUtility: false,
                            iconData: tool.iconData,
                            alias: tool.alias,
                            supportsQuery: tool.supportsQueryExtension,
                            defaultUrl: tool.defaultUrl
                        )
                        if hasAlias {
                            aliasTools[tool.alias!] = info
                        }
                        // 网页直达需要加入列表以支持名称搜索
                        allToolsList.append(info)
                    }
                case .utility:
                    if let identifier = tool.extensionIdentifier {
                        let info = MemoryIndex.AliasToolInfo(
                            name: tool.name,
                            path: identifier,
                            isWebLink: false,
                            isUtility: true,
                            iconData: tool.iconData,
                            alias: tool.alias,
                            supportsQuery: true,
                            defaultUrl: nil
                        )
                        if hasAlias {
                            aliasTools[tool.alias!] = info
                        }
                        allToolsList.append(info)
                    }
                case .systemCommand:
                    if let command = tool.command {
                        let info = MemoryIndex.AliasToolInfo(
                            name: tool.displayName,  // 使用动态名称
                            path: command,
                            isWebLink: false,
                            isUtility: false,
                            isSystemCommand: true,
                            iconData: nil,
                            alias: tool.alias,
                            supportsQuery: false,
                            defaultUrl: nil
                        )
                        if hasAlias {
                            aliasTools[tool.alias!] = info
                        }
                        allToolsList.append(info)
                    }
                }
            }

            memoryIndex.setAliasMapWithTools(aliasTools)
            // 设置所有工具列表（用于名称搜索）
            memoryIndex.setToolsList(allToolsList)
            print(
                "SearchEngine: Loaded \(aliasTools.count) aliases, \(allToolsList.count) tools from ToolsConfig"
            )
            return
        }

        // 回退到旧的 CustomItemsConfig
        let customConfig = CustomItemsConfig.load()
        let aliasMap = customConfig.aliasMap()
        memoryIndex.setAliasMap(aliasMap)
        print("SearchEngine: Loaded \(aliasMap.count) aliases from CustomItemsConfig")
    }

    // MARK: - Startup

    private func loadIndexOnStartup() {
        let startTime = Date()

        // Check if we have existing index
        let stats = database.getStatistics()

        if stats.totalCount > 0 {
            print("SearchEngine: Found existing index with \(stats.totalCount) items, loading...")

            // Optimized: Load in batches for better performance with large datasets
            loadIndexInBatches(startTime: startTime)
        } else {
            print("SearchEngine: No existing index, building fresh...")
            Task { @MainActor [weak self] in
                self?.buildFreshIndex()
            }
        }
    }

    /// Optimized batch loading for large datasets (600k+ files)
    /// 流式加载：数据库分批读取直接灌入内存索引，
    /// 不再把全量 FileRecord 物化成中间数组（峰值内存约为原来的一半）
    private func loadIndexInBatches(startTime: Date) {
        let batchSize = 10000  // Load 10k records at a time

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Get total count first
            let stats = self.database.getStatistics()
            print("SearchEngine: Streaming \(stats.totalCount) records into memory index...")

            var offset = 0

            self.memoryIndex.buildStreamed(chunkLoader: {
                guard offset < stats.totalCount else { return nil }
                let batch = self.database.loadBatch(offset: offset, limit: batchSize)
                if batch.isEmpty { return nil }
                offset += batch.count
                if offset % 50000 == 0 {
                    print("SearchEngine: Loaded \(offset)/\(stats.totalCount) records...")
                }
                return batch
            }) { [weak self] in
                guard let self = self else { return }

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.appsCount = self.memoryIndex.appsCount
                    self.filesCount = self.memoryIndex.filesCount
                    self.totalCount = self.memoryIndex.totalCount
                    self.indexingDuration = Date().timeIntervalSince(startTime)
                    self.lastIndexTime = Date()
                    self.isReady = true

                    print(
                        "SearchEngine: Loaded index in \(String(format: "%.3f", self.indexingDuration))s"
                    )

                    // 启动后台审计：清理 App 未运行期间删除等 FSEvents 覆盖不到的失效条目
                    self.scheduleStaleEntryAudit(delay: 30)
                }

                // Start file system monitoring
                // 延迟 5 秒启动，避免启动时的 I/O 响
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    self?.startMonitoring()
                }
            }
        }
    }

    // MARK: - Index Building

    /// Build index from scratch
    @MainActor
    func buildFreshIndex() {
        guard !isIndexing else { return }

        isIndexing = true
        isReady = false
        let startTime = Date()
        searchCache.clear()

        // Clear existing data
        database.deleteAll { [weak self] _ in
            guard let self = self else { return }

            // Get app scopes from config
            let config = self.searchConfig

            // First, quickly scan applications
            self.indexer.scanApplications(paths: config.appScopes) { count, path in
                Task { @MainActor [weak self] in
                    self?.indexProgress = (count, path)
                }
            } completion: { [weak self] appCount, _ in
                guard let self = self else { return }

                // Then scan document directories
                let config = self.searchConfig

                self.indexer.scan(
                    paths: config.documentScopes,
                    excludedPaths: config.excludedPaths,
                    excludedNames: Set(config.excludedFolderNames),
                    excludedExtensions: Set(config.excludedExtensions),
                    progress: { count, path in
                        Task { @MainActor [weak self] in
                            self?.indexProgress = (appCount + count, path)
                        }
                    },
                    completion: { [weak self] fileCount, duration in
                        guard let self = self else { return }

                        // Load everything into memory index
                        let records = self.database.loadAllSync()
                        self.memoryIndex.build(from: records) { [weak self] in
                            guard let self = self else { return }

                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.appsCount = self.memoryIndex.appsCount
                                self.filesCount = self.memoryIndex.filesCount
                                self.totalCount = self.memoryIndex.totalCount
                                self.indexingDuration = Date().timeIntervalSince(startTime)
                                self.lastIndexTime = Date()
                                self.isIndexing = false
                                self.isReady = true

                                print(
                                    "SearchEngine: Index built. Apps: \(self.appsCount), Files: \(self.filesCount), Duration: \(String(format: "%.2f", self.indexingDuration))s"
                                )
                            }

                            // Start monitoring
                            self.startMonitoring()
                        }
                    }
                )
            }
        }
    }

    /// Rebuild index (called when search scope changes)
    /// 直接使用全量重建，简单可靠
    @MainActor
    func rebuildIndex() {
        indexer.cancel()
        fsMonitor.stop()
        searchCache.clear()
        buildFreshIndex()
    }

    // MARK: - File System Monitoring

    private func startMonitoring() {
        let config = searchConfig
        let pathsToMonitor = config.appScopes + config.documentScopes

        fsMonitor.start(paths: pathsToMonitor) { [weak self] events in
            self?.handleFSEvents(events)
        }
    }

    private func handleFSEvents(_ events: [FSEventsMonitor.FSEvent]) {
        // 过滤掉位于 package（app / framework / plugin 等 bundle）内部的事件。
        // 新安装 app 时 FSEvents（kFSEventStreamCreateFlagFileEvents）会逐个上报 bundle 内部文件
        // （如 XXX.app/Contents/Info.plist、XXX.app/Contents/Resources/...），这些不是用户希望搜索的
        // 独立条目。此处与全量扫描 FileIndexer.scan 的 .skipsPackageDescendants 行为保持一致：
        // 保留 bundle 本身（如 XXX.app），跳过其内部文件。
        let validEvents = events.filter { !isInsidePackage(path: $0.path) }
        guard !validEvents.isEmpty else { return }

        // 汇总为「待删除 / 待新增」两个集合（modified = 删 + 加）
        var pathsToCreate: Set<String> = []
        var pathsToDelete: Set<String> = []

        for event in validEvents {
            switch event.type {
            case .created:
                pathsToCreate.insert(event.path)
            case .deleted:
                pathsToDelete.insert(event.path)
            case .modified:
                pathsToDelete.insert(event.path)
                pathsToCreate.insert(event.path)
            case .renamed:
                break
            }
        }

        // 如果批量处理被禁用，立即处理
        guard fsEventsBatchProcessingEnabled else {
            applyIndexUpdates(deleting: Array(pathsToDelete), creating: Array(pathsToCreate))
            return
        }

        // 磁盘写入优化: 批量处理文件系统事件
        // 收集事件到队列，延迟后批量处理，减少数据库事务次数
        fsEventQueue.append(contentsOf: validEvents)

        // 检查队列溢出保护（超过 1000 个事件立即处理）
        if fsEventQueue.count > 1000 {
            print("[SearchEngine] FSEvents queue overflow (\(fsEventQueue.count) events), processing immediately")
            processFSEventsBatch()
            return
        }

        // 重置定时器，延迟 300ms 后批量处理（与 FSEvents 1s 防抖配合，总延迟 ≤ 1.3s）
        fsEventTimer?.invalidate()
        fsEventTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) {
            [weak self] _ in
            self?.processFSEventsBatch()
        }
    }

    /// 批量处理 FSEvents 队列中的事件（磁盘写入优化）
    ///
    /// **FSEvents 批量处理优化**
    ///
    /// ## 原理
    /// 文件系统事件（FSEvents）通常会在短时间内产生大量事件。
    /// 通过收集事件到队列，延迟后批量处理，可以：
    /// 1. 合并重复事件（同一文件的多次修改）
    /// 2. 使用数据库事务批量插入/删除，减少事务开销
    /// 3. 减少数据库 checkpoint 频率
    ///
    /// ## 优化策略
    /// 1. **事件收集**：将 FSEvents 收集到队列，不立即处理
    /// 2. **延迟处理**：300ms 后批量处理队列中的所有事件
    /// 3. **溢出保护**：队列超过 1000 个事件时立即处理，防止内存溢出
    /// 4. **事务优化**：使用单个数据库事务处理所有事件
    ///
    /// ## 优化效果
    /// - 减少数据库写入次数：从每个事件一次写入，降低到每批一次批量写入
    /// - 降低 WAL checkpoint 频率：批量写入减少事务数量
    /// - 预期效果：索引相关写入量降低 70-80%
    ///
    /// ## 权衡
    /// - **索引延迟**：文件变化最多延迟约 1.3s 才会反映到索引
    /// - **用户影响**：用户创建文件后，可能需要等待约 1.3s 才能搜索到
    /// - **可接受性**：秒级延迟对大多数用户来说是可接受的
    ///
    /// ## 配置
    /// 可通过 `DiskWriteOptimizationSettings.fsEventsBatchProcessingEnabled` 开关控制
    ///
    private func processFSEventsBatch() {
        guard !fsEventQueue.isEmpty else { return }

        print("SearchEngine: Processing \(fsEventQueue.count) FSEvents in batch")

        // 汇总为「待删除 / 待新增」两个集合（modified = 删 + 加）
        var pathsToCreate: Set<String> = []
        var pathsToDelete: Set<String> = []

        for event in fsEventQueue {
            switch event.type {
            case .created:
                pathsToCreate.insert(event.path)
            case .deleted:
                pathsToDelete.insert(event.path)
            case .modified:
                pathsToDelete.insert(event.path)
                pathsToCreate.insert(event.path)
            case .renamed:
                break
            }
        }

        // 清空队列
        fsEventQueue.removeAll()
        fsEventTimer = nil

        // 批量处理完成后，检查是否需要执行 checkpoint（磁盘写入优化）
        checkAndForceCheckpoint()

        applyIndexUpdates(deleting: Array(pathsToDelete), creating: Array(pathsToCreate))
    }

    /// 应用索引增量（FSEvents 事件的统一处理入口）。
    ///
    /// - 删除走级联子树：Finder「移到废纸篓」、目录重命名 / 移动时 FSEvents 只上报目录本身，
    ///   子文件不会再有事件，必须按前缀一并清理（否则子文件永久残留在索引中）。
    /// - 新增目录补扫子树：目录移入监控范围 / 从废纸篓恢复 / 粘贴整目录时同样只有目录本身的事件，
    ///   子文件需要主动枚举入索引。
    /// - 先删后增，全部在后台线程执行；结束后清除搜索缓存并刷新统计。
    private func applyIndexUpdates(deleting: [String], creating: [String]) {
        let deleteRoots = Self.prefixCompress(deleting)
        guard !deleteRoots.isEmpty || !creating.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. 级联删除（SQLite 范围删除 + 内存子树移除；dbQueue 与索引队列都是串行的，
            //    删除操作先入队，保证后续新增的「先删后加」顺序）
            for root in deleteRoots {
                self.database.deleteSubtree(atPath: root)
                self.memoryIndex.removeSubtree(atPath: root)
            }
            if !deleteRoots.isEmpty {
                print("SearchEngine: Cascade removed \(deleteRoots.count) subtree root(s)")
            }

            // 2. 新增：目录补扫子树，文件单条
            if !creating.isEmpty {
                let config = self.searchConfig
                var records: [FileRecord] = []
                records.reserveCapacity(creating.count)

                for path in creating {
                    guard let record = self.createFileRecord(path: path, config: config) else {
                        continue
                    }
                    records.append(record)

                    // 目录 created 只上报目录本身，子文件没有事件，需要主动补扫
                    // （package 本身如 XXX.app 不展开，与全量扫描的 skipsPackageDescendants 对齐）
                    if record.isDirectory && !Self.isPackageBundle(path: path) {
                        records.append(
                            contentsOf: self.indexer.collectSubtreeRecords(
                                root: URL(fileURLWithPath: path),
                                excludedPaths: config.excludedPaths,
                                excludedNames: Set(config.excludedFolderNames),
                                excludedExtensions: Set(config.excludedExtensions)
                            ))
                    }
                }

                if !records.isEmpty {
                    self.database.insertBatch(records)
                    self.memoryIndex.addBatch(records)
                    print("SearchEngine: Batch inserted \(records.count) records")
                }
            }

            // 3. 索引内容已变化，清除搜索缓存，避免继续返回已删除的文件
            self.searchCache.clear()

            Task { @MainActor [weak self] in
                self?.refreshStatsFromMemoryIndex()
            }
        }
    }

    /// 前缀压缩：排序后仅保留互不为子路径的根（"/a/b" 吸收 "/a/b/c"）。
    /// rm -rf 会逐个上报子文件删除事件，压缩后变成一条子树级联删除。
    private static func prefixCompress(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else { return [] }
        var roots: [String] = []
        for path in paths.sorted() {
            if let last = roots.last, path == last || path.hasPrefix(last + "/") {
                continue
            }
            roots.append(path)
        }
        return roots
    }

    /// 已知的 macOS bundle / package 扩展名。
    /// 新安装 app 时 FSEvents 会枚举其内部文件，这些 bundle 内部文件不应进入索引。
    private static let packageExtensions: Set<String> = [
        "app",
        "bundle",
        "framework",
        "plugin",
        "kext",
        "prefpane",
        "osax",
        "qlgenerator",
        "mdimporter",
        "action",
        "menu",
        "pkg",
    ]

    /// 判断路径是否位于 package（app / framework / plugin 等 bundle）内部。
    ///
    /// 与全量扫描 `FileIndexer.scan` 的 `.skipsPackageDescendants` 行为对齐：保留 bundle 本身
    /// （如 `/Applications/X.app`），跳过其内部文件（如 `/Applications/X.app/Contents/Info.plist`）。
    ///
    /// - Parameter path: 待判断的文件路径
    /// - Returns: 若路径的某个中间组件是已知 bundle 扩展名则返回 true（应跳过）
    private func isInsidePackage(path: String) -> Bool {
        let components = (path as NSString).pathComponents
        guard components.count > 1 else { return false }
        // 仅检查“中间”组件（不含最后一段）：最后一段若是 .app，那它是 bundle 本身，应保留
        for component in components.dropLast() {
            let ext = (component as NSString).pathExtension.lowercased()
            if !ext.isEmpty, Self.packageExtensions.contains(ext) {
                return true
            }
        }
        return false
    }

    /// 判断路径本身是否是 package（app / framework 等 bundle）。
    /// 目录 created 事件命中 bundle 时不展开子树（bundle 内部文件不是用户要搜的条目），
    /// 与全量扫描的 .skipsPackageDescendants 行为对齐。
    private static func isPackageBundle(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && packageExtensions.contains(ext)
    }

    /// 创建文件记录（FSEvents 实时增量的入口）。
    /// 排除规则做全路径段检查；记录语义统一走 FileIndexer.makeRecord
    /// （保留扩展名、app 本地化名 + 无图标辅助程序过滤、拼音）。
    private func createFileRecord(path: String, config: SearchConfig) -> FileRecord? {
        let url = URL(fileURLWithPath: path)

        // Skip if excluded
        if config.excludedPaths.contains(where: { path.hasPrefix($0) }) { return nil }

        // 检查路径中每一段目录名（此前只查最后一段，
        // 新建于 node_modules 等排除目录下的文件会漏进索引）
        if !config.excludedFolderNames.isEmpty {
            let components = (path as NSString).pathComponents
            if !Set(config.excludedFolderNames).isDisjoint(with: components) { return nil }
        }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && config.excludedExtensions.contains(ext) { return nil }

        return FileIndexer.makeRecord(for: url)
    }

    private func removeFromIndex(path: String) {
        applyIndexUpdates(deleting: [path], creating: [])
    }

    /// 从索引中删除指定路径的文件（公开方法，用于文件被删除后更新索引）。
    /// 走级联子树删除：通过快捷操作删除整个文件夹时，子文件一并清理。
    func removeItem(at path: String) {
        removeFromIndex(path: path)
    }

    /// 从 MemoryIndex 刷新对外暴露的统计（主线程调用）
    @MainActor
    private func refreshStatsFromMemoryIndex() {
        totalCount = memoryIndex.totalCount
        appsCount = memoryIndex.appsCount
        filesCount = memoryIndex.filesCount
    }

    // MARK: - WAL Checkpoint 管理

    /// 启动 WAL checkpoint 定时器（磁盘写入优化）
    private func startWALCheckpointTimer() {
        let settings = DiskWriteOptimizationSettings.shared
        guard settings.idleCheckpointEnabled else { return }

        // 每5分钟检查一次
        let interval = settings.idleCheckpointIntervalSeconds
        walCheckpointTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.performIdleCheckpoint()
        }
    }

    /// 启动 Trie 定期重建定时器（内存回收）。
    /// MemoryIndex 移除时已会修剪 Trie，但仍可能残留碎片；定期全量重建可彻底回收死 TrieNode。
    /// 同时顺带触发一次失效条目审计。
    private func startTrieRebuildTimer() {
        trieRebuildTimer = Timer.scheduledTimer(withTimeInterval: trieRebuildInterval, repeats: true) { [weak self] _ in
            self?.memoryIndex.rebuildTries()
            Task { @MainActor [weak self] in
                self?.scheduleStaleEntryAudit(delay: 0)
            }
        }
    }

    // MARK: - 失效条目审计

    /// 调度后台审计（主线程调用）。已在调度中或正在全量索引时跳过。
    @MainActor
    private func scheduleStaleEntryAudit(delay: TimeInterval) {
        guard !staleAuditScheduled, !isIndexing else { return }
        staleAuditScheduled = true

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.runStaleEntryAudit()
        }
    }

    /// 校验索引中的路径是否仍存在于磁盘，清理失效条目。
    ///
    /// 覆盖 FSEvents 覆盖不到的场景：
    /// - App 未运行期间删除 / 移动的文件（FSEvents 只能感知运行期间的事件）
    /// - 事件被合并 / 丢弃（如监控启动前的 5 秒空窗）
    ///
    /// 在 utility QoS 上分块执行并节流，避免与用户操作抢 I/O；
    /// 失效路径经前缀压缩后按子树级联删除（目录被删时其下所有子路径一并清理）。
    private func runStaleEntryAudit() {
        let startTime = Date()
        let allPaths = memoryIndex.allIndexedPaths()

        defer {
            DispatchQueue.main.async { [weak self] in
                self?.staleAuditScheduled = false
            }
        }

        guard !allPaths.isEmpty else { return }

        print("SearchEngine: Auditing \(allPaths.count) indexed paths for stale entries...")

        let fileManager = FileManager.default
        var stalePaths: [String] = []

        for (index, path) in allPaths.enumerated() {
            if !fileManager.fileExists(atPath: path) {
                stalePaths.append(path)
            }
            // 分块节流，避免一次性打满磁盘 I/O
            if index % 4096 == 4095 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let roots = Self.prefixCompress(stalePaths)
        let duration = Date().timeIntervalSince(startTime)

        guard !roots.isEmpty else {
            print(
                "SearchEngine: Audit complete, no stale entries (\(String(format: "%.2f", duration))s)"
            )
            return
        }

        print(
            "SearchEngine: Audit found \(stalePaths.count) stale entries (compressed to \(roots.count) roots), purging..."
        )

        for root in roots {
            database.deleteSubtree(atPath: root)
            memoryIndex.removeSubtree(atPath: root)
        }

        searchCache.clear()

        Task { @MainActor [weak self] in
            self?.refreshStatsFromMemoryIndex()
            print(
                "SearchEngine: Audit purged \(stalePaths.count) stale entries in \(String(format: "%.2f", duration))s"
            )
        }
    }

    /// 执行空闲时的 checkpoint
    private func performIdleCheckpoint() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.database.idleCheckpoint()
        }
    }

    /// 检查并强制执行 checkpoint（当 WAL 文件过大时）
    private func checkAndForceCheckpoint() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.database.checkAndForceCheckpoint()
        }
    }

    // MARK: - Search

    /// Optimized synchronous search with caching and performance monitoring
    /// This is the main search API, called on every keystroke
    func searchSync(text: String) -> [SearchResult] {
        guard !text.isEmpty else { return [] }

        // Check cache first — duplicate queries hit O(1) instead of full Trie scan
        if let cached = searchCache.getCachedResults(for: text) {
            return performanceMonitor.measureSearch(query: text, cacheHit: true) {
                cached
            }
        }

        return performanceMonitor.measureSearch(query: text, cacheHit: false) {
            let config = searchConfig

            // Use optimized search
            let items = memoryIndex.search(
                query: text,
                excludedApps: config.excludedApps,
                excludedPaths: config.excludedPaths,
                excludedExtensions: Set(config.excludedExtensions),
                excludedFolderNames: Set(config.excludedFolderNames)
            )

            var results = items.map { $0.toSearchResult() }

            // 添加书签搜索结果
            let bookmarkResults = searchBookmarks(query: text)
            results.append(contentsOf: bookmarkResults)

            // Cache results for duplicate queries (e.g., user backspacing)
            searchCache.cacheResults(results, for: text)

            return results
        }
    }

    // MARK: - 书签搜索

    /// 搜索书签
    private func searchBookmarks(query: String) -> [SearchResult] {
        guard cachedBookmarkSettings.isEnabled else { return [] }

        let bookmarks = BookmarkService.shared.search(query: query)
        return bookmarks.prefix(10).map { bookmark in
            SearchResult(
                name: bookmark.title,
                path: bookmark.url,
                icon: bookmark.source.icon,
                isDirectory: false,
                isBookmark: true,
                bookmarkSource: bookmark.source.rawValue
            )
        }
    }

    // MARK: - 默认搜索网页直达

    /// 获取设置为默认显示在搜索面板的网页直达列表
    /// 仅返回已启用、支持 query 扩展且设置了 showInSearchPanel 的网页直达
    func getDefaultSearchWebLinks() -> [SearchResult] {
        // 使用缓存避免每次搜索都重新构建
        if let cached = cachedDefaultSearchWebLinks {
            return cached
        }

        let toolsConfig = ToolsConfig.load()
        var results: [SearchResult] = []

        for tool in toolsConfig.enabledTools {
            // 只处理网页直达
            guard tool.type == .webLink,
                let url = tool.url,
                tool.supportsQueryExtension,
                tool.showInSearchPanel == true
            else { continue }

            // 创建图标
            var icon: NSImage
            if let iconData = tool.iconData, let customIcon = NSImage(data: iconData) {
                customIcon.size = NSSize(width: 32, height: 32)
                icon = customIcon
            } else {
                icon =
                    NSImage(systemSymbolName: "globe", accessibilityDescription: "Web Link")
                    ?? NSImage()
                icon.size = NSSize(width: 32, height: 32)
            }

            let result = SearchResult(
                name: tool.name,
                path: url,
                icon: icon,
                isDirectory: false,
                displayAlias: tool.alias,
                isWebLink: true,
                supportsQueryExtension: true,
                defaultUrl: tool.defaultUrl
            )
            results.append(result)
        }

        cachedDefaultSearchWebLinks = results
        return results
    }
}
