import Cocoa
import Combine
import Foundation

/// A high-performance service that builds and maintains an in-memory index
/// of files using the high-level NSMetadataQuery API.
class MetadataQueryService: ObservableObject {
    static let shared = MetadataQueryService()

    @Published var isIndexing: Bool = false
    @Published var indexedItemCount: Int = 0

    // The main in-memory index
    private(set) var indexedItems: [IndexedItem] = []

    // Processing queue for heavy lifting (Pinyin calculation)
    private let processingQueue = DispatchQueue(
        label: "com.launchx.metadata.processing", qos: .userInitiated)

    private var query: NSMetadataQuery?
    private var searchConfig: SearchConfig = SearchConfig()

    private init() {}

    // MARK: - Public API

    /// Starts or restarts the indexing process based on the provided configuration.
    func startIndexing(with config: SearchConfig) {
        // Ensure main thread for NSMetadataQuery setup
        DispatchQueue.main.async {
            self.stopIndexing()

            self.searchConfig = config
            self.isIndexing = true

            let query = NSMetadataQuery()
            self.query = query

            // Set Search Scopes
            query.searchScopes = config.searchScopes

            // Predicate
            // Equivalent to: kMDItemContentTypeTree == "public.item" && kMDItemContentType != "com.apple.systempreference.prefpane"
            let predicate = NSPredicate(
                format:
                    "%K == 'public.item' AND %K != 'com.apple.systempreference.prefpane'",
                NSMetadataItemContentTypeTreeKey,
                NSMetadataItemContentTypeKey
            )
            query.predicate = predicate

            // Observers
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

            // Start the query on the Main RunLoop
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
            self.isIndexing = false
        }
    }

    /// Fast in-memory search using Pinyin matcher
    func search(text: String, limit: Int = 50) -> [IndexedItem] {
        guard !text.isEmpty else { return [] }

        // Filter on main thread (fast for <50k items)
        let itemsToCheck = indexedItems

        let matches = itemsToCheck.filter { item in
            item.searchableName.matches(text)
        }

        // Sort
        let sorted = matches.sorted { lhs, rhs in
            // Prefer shorter names (exact matches)
            if lhs.name.count != rhs.name.count {
                return lhs.name.count < rhs.name.count
            }
            // Prefer newer files
            return lhs.lastUsed > rhs.lastUsed
        }

        return Array(sorted.prefix(limit))
    }

    // MARK: - Query Handlers

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        print("MetadataQueryService: NSMetadataQuery finished gathering")
        processQueryResults(isInitial: true)
        isIndexing = false
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        processQueryResults(isInitial: false)
    }

    private func processQueryResults(isInitial: Bool) {
        guard let query = query else { return }

        // Pause live updates to ensure stability during iteration
        query.disableUpdates()

        // Capture snapshot on Main Thread (fast)
        let results = query.results as? [NSMetadataItem] ?? []

        // Resume updates immediately so we don't block the query for long
        query.enableUpdates()

        // Offload processing to background
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            let count = results.count
            var newItems: [IndexedItem] = []
            newItems.reserveCapacity(count)

            // Prepare exclusion checks
            let excludedPaths = self.searchConfig.excludedPaths
            let excludedNames = self.searchConfig.excludedNames
            let excludedNamesSet = Set(excludedNames)

            // Iterate results
            for item in results {
                // Get Path
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
                    continue
                }

                // --- High Performance Filtering ---

                // 1. Path Exclusion (e.g. inside .git or node_modules)
                let pathComponents = path.components(separatedBy: "/")

                // Optimization: Quick check if any excluded name exists in path
                if !excludedNamesSet.isDisjoint(with: pathComponents) { continue }

                // 2. Exact Path Exclusion
                if !excludedPaths.isEmpty {
                    if excludedPaths.contains(where: { path.hasPrefix($0) }) { continue }
                }

                // --- Extraction ---

                // Prioritize Display Name (Localized) for Pinyin
                let name =
                    item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String
                    ?? item.value(forAttribute: NSMetadataItemFSNameKey) as? String
                    ?? (path as NSString).lastPathComponent

                let date =
                    item.value(forAttribute: NSMetadataItemContentModificationDateKey) as? Date
                    ?? Date()

                // Check if directory
                let contentType = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                let isDirectory =
                    (contentType == "public.folder" || contentType == "com.apple.mount-point")

                let cachedItem = IndexedItem(
                    id: UUID(),
                    name: name,
                    path: path,
                    lastUsed: date,
                    isDirectory: isDirectory,
                    searchableName: CachedSearchableString(name)
                )

                newItems.append(cachedItem)
            }

            // Update State on Main Thread
            DispatchQueue.main.async {
                self.indexedItems = newItems
                self.indexedItemCount = newItems.count

                if isInitial {
                    print(
                        "MetadataQueryService: Initial index complete. Total filtered items: \(newItems.count)"
                    )
                }
            }
        }
    }
}

// MARK: - Models

struct IndexedItem: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let lastUsed: Date
    let isDirectory: Bool
    let searchableName: CachedSearchableString

    // Convert to the UI model
    func toSearchResult() -> SearchResult {
        return SearchResult(
            id: id,
            name: name,
            path: path,
            icon: NSWorkspace.shared.icon(forFile: path),
            isDirectory: isDirectory
        )
    }
}
