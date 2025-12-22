import Cocoa
import Combine
import Foundation

/// A high-performance service that builds and maintains an in-memory index
/// of files using the high-level NSMetadataQuery API.
///
/// Workflow:
/// 1. Uses NSMetadataQuery to fetch metadata for configured scopes efficiently.
/// 2. Captures results snapshot on the main thread (fast).
/// 3. Offloads metadata extraction and heavy processing (Pinyin) to concurrent background threads.
/// 4. Splits index into Apps and Files for prioritized searching.
/// 5. Provides sync search with pre-computed pinyin for fast Chinese input matching.
class MetadataQueryService: ObservableObject {
    static let shared = MetadataQueryService()

    @Published var isIndexing: Bool = false
    @Published var indexedItemCount: Int = 0

    // Index statistics
    @Published var appsCount: Int = 0
    @Published var filesCount: Int = 0
    @Published var indexingDuration: TimeInterval = 0
    @Published var lastIndexTime: Date?

    // Split index for optimization
    // IndexedItem is a class, so array copies are cheap (copying references)
    private var appsIndex: [IndexedItem] = []
    private var filesIndex: [IndexedItem] = []

    // Track indexed paths to avoid re-processing
    private var indexedPaths: Set<String> = []

    // Processing queue for search requests
    private let searchQueue = DispatchQueue(
        label: "com.launchx.metadata.search", qos: .userInteractive)

    // Global concurrent queue for heavy indexing
    private let indexingQueue = DispatchQueue.global(qos: .userInitiated)

    private var query: NSMetadataQuery?
    private var searchConfig: SearchConfig = SearchConfig()
    private var configObserver: NSObjectProtocol?
    private var indexingStartTime: Date?

    // Cancellation token for search requests
    private var currentSearchWorkItem: DispatchWorkItem?

    // Throttle updates to avoid CPU spikes
    private var lastUpdateTime: Date = .distantPast
    private var pendingUpdateWorkItem: DispatchWorkItem?
    private let updateThrottleInterval: TimeInterval = 2.0  // Minimum 2 seconds between updates
    private var initialIndexingComplete = false

    private init() {
        // Listen for config changes
        configObserver = NotificationCenter.default.addObserver(
            forName: .searchConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let config = notification.object as? SearchConfig {
                self?.reloadWithConfig(config)
            }
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Reload indexing with new config
    func reloadWithConfig(_ config: SearchConfig) {
        print("MetadataQueryService: Reloading with new config")
        startIndexing(with: config)
    }

    // MARK: - Public API

    func startIndexing(with config: SearchConfig) {
        DispatchQueue.main.async {
            self.stopIndexing()
            self.searchConfig = config
            self.isIndexing = true
            self.indexingStartTime = Date()

            let query = NSMetadataQuery()
            self.query = query

            query.searchScopes = config.searchScopes

            // Predicate: Match all items whose content type tree contains 'public.item'
            // This includes: applications, files, folders, etc.
            // Using 'CONTAINS' instead of '==' because ContentTypeTree is an array
            // Exclude system preference panes
            let predicate = NSPredicate(
                format: "%K CONTAINS 'public.item' AND %K != 'com.apple.systempreference.prefpane'",
                NSMetadataItemContentTypeTreeKey,
                NSMetadataItemContentTypeKey
            )
            query.predicate = predicate

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.queryDidFinishGathering(_:)),
                name: .NSMetadataQueryDidFinishGathering,
                object: query
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.queryDidUpdate(_:)),
                name: .NSMetadataQueryDidUpdate,
                object: query
            )

            print(
                "MetadataQueryService: Starting NSMetadataQuery with scopes: \(config.searchScopes)"
            )
            if !query.start() {
                print("MetadataQueryService: Failed to start NSMetadataQuery")
                self.isIndexing = false
            }
        }
    }

    func stopIndexing() {
        if let query = query {
            query.stop()
            NotificationCenter.default.removeObserver(
                self, name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.removeObserver(
                self, name: .NSMetadataQueryDidUpdate, object: query)
            self.query = nil
        }
        // Clear old index data
        appsIndex.removeAll()
        filesIndex.removeAll()
        indexedPaths.removeAll()
        isIndexing = false
        initialIndexingComplete = false
    }

    // MARK: - Search Logic

    /// Synchronous search for immediate results - called on every keystroke
    /// This must be EXTREMELY fast (< 1ms) to not block typing
    /// HapiGo-style: pure in-memory query, no I/O, no thread switching
    /// Now with pre-computed pinyin support for Chinese users
    func searchSync(text: String) -> [IndexedItem] {
        guard !text.isEmpty else { return [] }

        let lowerQuery = text.lowercased()
        let queryIsAscii = text.isAscii

        // 1. Search Apps first (usually small, ~100-500 items)
        // Use tuple to track match type for sorting
        var matchedApps: [(item: IndexedItem, matchType: IndexedItem.MatchType)] = []
        matchedApps.reserveCapacity(10)

        for app in appsIndex {
            // Check display name and filename
            if let matchType = app.matchesQuery(lowerQuery) {
                matchedApps.append((app, matchType))
                continue
            }
            // Pinyin match: only if query is ASCII (user typing pinyin)
            // Uses pre-computed pinyin fields for O(1) lookup
            if queryIsAscii && app.matchesPinyin(lowerQuery) {
                matchedApps.append((app, .pinyin))
            }
        }

        // Sort apps: by match type, then by name length (shorter = more relevant)
        matchedApps.sort { lhs, rhs in
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.name.count < rhs.item.name.count
        }

        // 2. Search Files (limit iterations for speed)
        var matchedFiles: [(item: IndexedItem, matchType: IndexedItem.MatchType)] = []
        matchedFiles.reserveCapacity(20)

        let maxFileIterations = min(filesIndex.count, 5000)  // Cap iterations
        for i in 0..<maxFileIterations {
            let file = filesIndex[i]

            if let matchType = file.matchesQuery(lowerQuery) {
                matchedFiles.append((file, matchType))
                if matchedFiles.count >= 20 { break }
                continue
            }
            // Pinyin match for files too
            if queryIsAscii && file.matchesPinyin(lowerQuery) {
                matchedFiles.append((file, .pinyin))
                if matchedFiles.count >= 20 { break }
            }
        }

        // Sort files: by match type, then by last used date
        matchedFiles.sort { lhs, rhs in
            if lhs.matchType != rhs.matchType {
                return lhs.matchType < rhs.matchType
            }
            return lhs.item.lastUsed > rhs.item.lastUsed
        }

        // Combine: Apps first (max 10), then Files (max 20)
        let topApps = matchedApps.prefix(10).map { $0.item }
        let topFiles = matchedFiles.prefix(20).map { $0.item }

        return Array(topApps) + Array(topFiles)
    }

    /// Async search with batch processing for responsiveness.
    /// - Parameters:
    ///   - text: The search query.
    ///   - completion: Callback with results (Apps first, then Files).
    func search(text: String, completion: @escaping ([IndexedItem]) -> Void) {
        // Cancel previous pending search
        currentSearchWorkItem?.cancel()

        guard !text.isEmpty else {
            completion([])
            return
        }

        // Snapshot indices (Cheap pointer copy since IndexedItem is a class)
        let apps = self.appsIndex
        let files = self.filesIndex

        // Pre-compute query specifics once
        let lowerQuery = text.lowercased()
        let queryIsAscii = text.isAscii

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Helper to check cancellation
            func isCancelled() -> Bool {
                return self.currentSearchWorkItem?.isCancelled ?? true
            }

            if isCancelled() { return }

            // 1. Apps Search (Batch processing)
            var matchedApps: [(item: IndexedItem, matchType: IndexedItem.MatchType)] = []
            let appChunkSize = 200

            for i in stride(from: 0, to: apps.count, by: appChunkSize) {
                if isCancelled() { return }

                let end = min(i + appChunkSize, apps.count)
                let chunk = apps[i..<end]

                for app in chunk {
                    if let matchType = app.matchesQuery(lowerQuery) {
                        matchedApps.append((app, matchType))
                        continue
                    }
                    if queryIsAscii && app.matchesPinyin(lowerQuery) {
                        matchedApps.append((app, .pinyin))
                    }
                }
            }

            // Sort Apps by match type, then by usage
            let sortedApps = matchedApps.sorted { lhs, rhs in
                if lhs.matchType != rhs.matchType {
                    return lhs.matchType < rhs.matchType
                }
                return lhs.item.lastUsed > rhs.item.lastUsed
            }

            let topApps = sortedApps.prefix(10).map { $0.item }

            if isCancelled() { return }

            // 2. Files Search (Batch processing)
            var matchedFiles: [(item: IndexedItem, matchType: IndexedItem.MatchType)] = []
            let fileChunkSize = 1000  // Process files in larger chunks

            for i in stride(from: 0, to: files.count, by: fileChunkSize) {
                if isCancelled() { return }

                let end = min(i + fileChunkSize, files.count)
                let chunk = files[i..<end]

                for file in chunk {
                    if let matchType = file.matchesQuery(lowerQuery) {
                        matchedFiles.append((file, matchType))
                        continue
                    }
                    if queryIsAscii && file.matchesPinyin(lowerQuery) {
                        matchedFiles.append((file, .pinyin))
                    }
                }
            }

            let sortedFiles = matchedFiles.sorted { lhs, rhs in
                if lhs.matchType != rhs.matchType {
                    return lhs.matchType < rhs.matchType
                }
                return lhs.item.lastUsed > rhs.item.lastUsed
            }

            let topFiles = sortedFiles.prefix(20).map { $0.item }

            let combined = Array(topApps) + Array(topFiles)

            DispatchQueue.main.async {
                // Ensure we are still the relevant search
                if !isCancelled() {
                    completion(combined)
                }
            }
        }

        self.currentSearchWorkItem = workItem
        searchQueue.async(execute: workItem)
    }

    // MARK: - Handlers

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        print("MetadataQueryService: NSMetadataQuery finished gathering")
        processQueryResults(isInitial: true)
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        // DISABLED: Live updates cause CPU spikes during window/space switching
        // The initial index is sufficient for most use cases
        // Users can restart the app to re-index if needed
        return

        // Original code kept for reference:
        /*
        guard initialIndexingComplete else { return }
        pendingUpdateWorkItem?.cancel()
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUpdateTime)
        if timeSinceLastUpdate >= updateThrottleInterval {
            lastUpdateTime = now
            processQueryResults(isInitial: false)
        } else {
            let delay = updateThrottleInterval - timeSinceLastUpdate
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lastUpdateTime = Date()
                self.processQueryResults(isInitial: false)
            }
            pendingUpdateWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
        */
    }

    private func processQueryResults(isInitial: Bool) {
        guard let query = query else { return }

        // Pause live updates to ensure stability during iteration
        query.disableUpdates()

        // Capture snapshot on Main Thread (fast)
        let results = query.results as? [NSMetadataItem] ?? []

        // Resume updates immediately
        query.enableUpdates()

        if results.isEmpty {
            if isInitial {
                isIndexing = false
                initialIndexingComplete = true
            }
            return
        }

        // Offload ALL processing to background
        indexingQueue.async { [weak self] in
            guard let self = self else { return }

            let count = results.count

            // For incremental updates, only process new items
            let existingPaths = self.indexedPaths
            var newItems: [(NSMetadataItem, String)] = []

            for item in results {
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
                    continue
                }
                if !existingPaths.contains(path) {
                    newItems.append((item, path))
                }
            }

            // If this is just an update with no new items, skip processing
            if !isInitial && newItems.isEmpty {
                return
            }

            // For initial indexing, process all items in parallel
            // For updates, only process new items
            let itemsToProcess: [(item: NSMetadataItem, path: String)]
            if isInitial {
                itemsToProcess = results.compactMap { item -> (NSMetadataItem, String)? in
                    guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else {
                        return nil
                    }
                    return (item, path)
                }
            } else {
                itemsToProcess = newItems
            }

            let processCount = itemsToProcess.count
            if processCount == 0 {
                if isInitial {
                    DispatchQueue.main.async {
                        self.isIndexing = false
                        self.initialIndexingComplete = true
                    }
                }
                return
            }

            // Use UnsafeMutablePointer for lock-free parallel writing of object references
            let tempBuffer = UnsafeMutablePointer<IndexedItem?>.allocate(capacity: processCount)
            tempBuffer.initialize(repeating: nil, count: processCount)

            defer {
                tempBuffer.deinitialize(count: processCount)
                tempBuffer.deallocate()
            }

            // Capture config for thread safety
            let excludedPaths = self.searchConfig.excludedPaths
            let excludedNames = self.searchConfig.excludedFolderNames
            let excludedNamesSet = Set(excludedNames)
            let excludedExtensions = Set(self.searchConfig.excludedExtensions)

            // Parallel Loop
            DispatchQueue.concurrentPerform(iterations: processCount) { i in
                let (item, path) = itemsToProcess[i]

                let pathComponents = path.components(separatedBy: "/")

                // Filtering by folder names
                if !excludedNamesSet.isDisjoint(with: pathComponents) { return }

                // Filtering by paths
                if !excludedPaths.isEmpty {
                    if excludedPaths.contains(where: { path.hasPrefix($0) }) { return }
                }

                // Filtering by file extension
                if !excludedExtensions.isEmpty {
                    let ext = (path as NSString).pathExtension.lowercased()
                    if excludedExtensions.contains(ext) { return }
                }

                // Prioritize Display Name
                let name =
                    item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                    ?? item.value(forAttribute: NSMetadataItemFSNameKey) as? String
                    ?? (path as NSString).lastPathComponent

                let date =
                    item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date
                    ?? Date()

                let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String

                // Object Creation (Heavy Pinyin Calculation happens here inside init)
                let isDirectory =
                    (contentType == "public.folder" || contentType == "com.apple.mount-point")
                let isApp = (contentType == "com.apple.application-bundle")

                let indexedItem = IndexedItem(
                    name: name,
                    path: path,
                    lastUsed: date,
                    isDirectory: isDirectory,
                    isApp: isApp
                )

                tempBuffer[i] = indexedItem
            }

            // Collect results
            var newApps: [IndexedItem] = []
            var newFiles: [IndexedItem] = []
            var newPaths: Set<String> = []

            if isInitial {
                newApps.reserveCapacity(500)
                newFiles.reserveCapacity(processCount)
            }

            for i in 0..<processCount {
                if let item = tempBuffer[i] {
                    newPaths.insert(item.path)
                    if item.isApp {
                        newApps.append(item)
                    } else {
                        newFiles.append(item)
                    }
                }
            }

            // Initial sort for Apps by name length (shorter names are usually more relevant)
            if isInitial {
                newApps.sort { $0.name.count < $1.name.count }
            }

            // Update State on Main Thread
            DispatchQueue.main.async {
                if isInitial {
                    // Full replacement for initial indexing
                    self.appsIndex = newApps
                    self.filesIndex = newFiles
                    self.indexedPaths = newPaths
                } else {
                    // Append new items for incremental updates
                    self.appsIndex.append(contentsOf: newApps)
                    self.filesIndex.append(contentsOf: newFiles)
                    self.indexedPaths.formUnion(newPaths)

                    // Re-sort apps if we added new ones
                    if !newApps.isEmpty {
                        self.appsIndex.sort { $0.name.count < $1.name.count }
                    }
                }

                self.indexedItemCount = self.appsIndex.count + self.filesIndex.count
                self.appsCount = self.appsIndex.count
                self.filesCount = self.filesIndex.count
                self.isIndexing = false

                if isInitial {
                    self.initialIndexingComplete = true

                    // Update statistics
                    if let startTime = self.indexingStartTime {
                        self.indexingDuration = Date().timeIntervalSince(startTime)
                    }
                    self.lastIndexTime = Date()

                    print(
                        "MetadataQueryService: Indexing complete. Apps: \(self.appsIndex.count), Files: \(self.filesIndex.count), Duration: \(String(format: "%.3f", self.indexingDuration))s"
                    )

                    // IMPORTANT: Stop the query after initial indexing to prevent CPU spikes
                    // Live updates are not worth the CPU cost during window/space switching
                    self.query?.stop()
                    print("MetadataQueryService: Query stopped to save CPU")

                    // Pre-load icons for apps in background (apps are most frequently accessed)
                    let appsToPreload = self.appsIndex
                    DispatchQueue.global(qos: .utility).async {
                        for app in appsToPreload {
                            app.preloadIcon()
                        }
                        print("MetadataQueryService: App icons preloaded")
                    }
                } else if !newApps.isEmpty || !newFiles.isEmpty {
                    print(
                        "MetadataQueryService: Incremental update. Added \(newApps.count) apps, \(newFiles.count) files"
                    )
                }
            }
        }
    }
}

// MARK: - Models

/// Changed from struct to final class to avoid Copy-On-Write overhead during search filtering
/// Now includes pre-computed pinyin fields for fast Chinese input matching
/// Also includes lowerFileName to support searching by actual filename (e.g., "Terminal" for "终端")
final class IndexedItem: Identifiable {
    let id = UUID()
    let name: String  // Display name (localized, e.g., "终端")
    let lowerName: String  // Lowercase display name for search
    let lowerFileName: String  // Lowercase actual filename for search (e.g., "terminal.app")
    let path: String
    let lastUsed: Date
    let isDirectory: Bool
    let isApp: Bool

    // Pre-computed pinyin for fast matching (computed once during indexing)
    // These are only populated for names containing Chinese characters
    private let pinyinFull: String?  // e.g., "weixin" for "微信"
    private let pinyinAcronym: String?  // e.g., "wx" for "微信"
    private let hasPinyin: Bool

    // Pre-cached icon - loaded during indexing, not during display
    private var _icon: NSImage?
    private var iconLoaded = false
    private let iconLock = NSLock()

    var icon: NSImage {
        iconLock.lock()
        defer { iconLock.unlock() }

        if !iconLoaded {
            _icon = NSWorkspace.shared.icon(forFile: path)
            _icon?.size = NSSize(width: 32, height: 32)
            iconLoaded = true
        }
        return _icon ?? NSImage()
    }

    // Pre-load icon in background (call this during indexing)
    func preloadIcon() {
        iconLock.lock()
        if iconLoaded {
            iconLock.unlock()
            return
        }
        iconLock.unlock()

        _icon = NSWorkspace.shared.icon(forFile: path)
        _icon?.size = NSSize(width: 32, height: 32)

        iconLock.lock()
        iconLoaded = true
        iconLock.unlock()
    }

    init(
        name: String, path: String, lastUsed: Date, isDirectory: Bool, isApp: Bool
    ) {
        self.name = name
        self.lowerName = name.lowercased()  // Pre-compute for fast search
        self.path = path
        self.lastUsed = lastUsed
        self.isDirectory = isDirectory
        self.isApp = isApp

        // Extract and store lowercase filename from path
        // e.g., "/System/Applications/Utilities/Terminal.app" -> "terminal.app"
        let fileName = (path as NSString).lastPathComponent
        self.lowerFileName = fileName.lowercased()

        // Pre-compute pinyin only for names with Chinese characters
        // This is done once during indexing, not during each search
        if name.hasMultiByteCharacters {
            let pinyin = name.pinyin.lowercased()
            self.pinyinFull = pinyin.replacingOccurrences(of: " ", with: "")
            self.pinyinAcronym = name.pinyinAcronym.lowercased()
            self.hasPinyin = true
        } else {
            self.pinyinFull = nil
            self.pinyinAcronym = nil
            self.hasPinyin = false
        }
    }

    /// Check if this item matches the query (display name or filename)
    /// Returns the match type if matched, nil otherwise
    @inline(__always)
    func matchesQuery(_ lowerQuery: String) -> MatchType? {
        // Check display name first
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

    /// Match type for sorting priority (moved here for visibility)
    enum MatchType: Int, Comparable {
        case exact = 0  // 精确匹配 (最高优先级)
        case prefix = 1  // 前缀匹配
        case contains = 2  // 包含匹配
        case pinyin = 3  // 拼音匹配 (最低优先级)

        static func < (lhs: MatchType, rhs: MatchType) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// Fast pinyin matching using pre-computed fields
    /// Returns true if the query matches pinyin full or acronym
    @inline(__always)
    func matchesPinyin(_ lowerQuery: String) -> Bool {
        guard hasPinyin else { return false }

        // Check acronym first (usually shorter, faster to match)
        // e.g., "wx" matches "微信"
        if let acronym = pinyinAcronym, acronym.hasPrefix(lowerQuery) {
            return true
        }

        // Check full pinyin
        // e.g., "weixin" or "weixi" matches "微信"
        if let full = pinyinFull, full.hasPrefix(lowerQuery) {
            return true
        }

        // Also check contains for partial matches
        if let full = pinyinFull, full.contains(lowerQuery) {
            return true
        }

        return false
    }

    func toSearchResult() -> SearchResult {
        return SearchResult(
            id: id,
            name: name,
            path: path,
            icon: icon,  // Use pre-cached icon
            isDirectory: isDirectory
        )
    }
}
