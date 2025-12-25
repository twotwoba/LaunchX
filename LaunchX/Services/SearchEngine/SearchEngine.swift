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

    private var configObserver: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var customItemsConfigObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        setupConfigObserver()
        setupCustomItemsConfigObserver()
        loadIndexOnStartup()
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
        customItemsConfigObserver = NotificationCenter.default.addObserver(
            forName: .customItemsConfigDidChange,
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
        let customConfig = CustomItemsConfig.load()
        let aliasMap = customConfig.aliasMap()
        memoryIndex.setAliasMap(aliasMap)
        print("SearchEngine: Loaded \(aliasMap.count) aliases")
    }

    // MARK: - Startup

    private func loadIndexOnStartup() {
        let startTime = Date()

        // Check if we have existing index
        let stats = database.getStatistics()

        if stats.totalCount > 0 {
            print("SearchEngine: Found existing index with \(stats.totalCount) items, loading...")

            // Load from database
            let records = database.loadAllSync()

            memoryIndex.build(from: records) { [weak self] in
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
                }

                // Start file system monitoring
                self.startMonitoring()
            }
        } else {
            print("SearchEngine: No existing index, building fresh...")
            Task { @MainActor [weak self] in
                self?.buildFreshIndex()
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
        for event in events {
            switch event.type {
            case .created:
                addToIndex(path: event.path)
            case .deleted:
                removeFromIndex(path: event.path)
            case .modified:
                // For modifications, we could update metadata
                // For now, just re-add
                removeFromIndex(path: event.path)
                addToIndex(path: event.path)
            case .renamed:
                // Handled as create/delete
                break
            }
        }
    }

    private func addToIndex(path: String) {
        let url = URL(fileURLWithPath: path)

        // Skip if excluded
        let config = searchConfig
        if config.excludedPaths.contains(where: { path.hasPrefix($0) }) { return }

        let fileName = url.lastPathComponent
        if config.excludedFolderNames.contains(fileName) { return }

        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && config.excludedExtensions.contains(ext) { return }

        // Create record
        guard
            let resourceValues = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .contentModificationDateKey,
            ])
        else { return }

        let name = url.deletingPathExtension().lastPathComponent
        let isApp = ext == "app"
        let isDir = resourceValues.isDirectory ?? false

        var pinyinFull: String? = nil
        var pinyinAcronym: String? = nil
        if name.hasMultiByteCharacters {
            pinyinFull = name.pinyin.lowercased().replacingOccurrences(of: " ", with: "")
            pinyinAcronym = name.pinyinAcronym.lowercased()
        }

        let record = FileRecord(
            name: name,
            path: path,
            extension: ext,
            isApp: isApp,
            isDirectory: isDir,
            pinyinFull: pinyinFull,
            pinyinAcronym: pinyinAcronym,
            modifiedDate: resourceValues.contentModificationDate
        )

        database.insert(record)
        memoryIndex.add(record)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.totalCount = self.memoryIndex.totalCount
            if isApp {
                self.appsCount = self.memoryIndex.appsCount
            } else {
                self.filesCount = self.memoryIndex.filesCount
            }
        }
    }

    private func removeFromIndex(path: String) {
        database.delete(path: path)
        memoryIndex.remove(path: path)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.totalCount = self.memoryIndex.totalCount
            self.appsCount = self.memoryIndex.appsCount
            self.filesCount = self.memoryIndex.filesCount
        }
    }

    // MARK: - Search

    /// Synchronous search for immediate results
    /// This is the main search API, called on every keystroke
    func searchSync(text: String) -> [SearchResult] {
        guard !text.isEmpty else { return [] }

        let config = searchConfig

        let items = memoryIndex.search(
            query: text,
            excludedApps: config.excludedApps,
            excludedPaths: config.excludedPaths,
            excludedExtensions: Set(config.excludedExtensions),
            excludedFolderNames: Set(config.excludedFolderNames)
        )

        return items.map { $0.toSearchResult() }
    }
}
