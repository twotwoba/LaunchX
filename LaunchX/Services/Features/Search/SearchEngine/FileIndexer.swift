import Cocoa
import CoreServices
import Foundation

/// File system scanner for building the initial index
/// Uses lazy enumeration for memory efficiency
final class FileIndexer {

    /// Progress callback: (scannedCount, currentPath)
    typealias ProgressCallback = (Int, String) -> Void

    /// Completion callback: (totalIndexed, duration)
    typealias CompletionCallback = (Int, TimeInterval) -> Void

    private let database = IndexDatabase.shared
    private let batchSize = 1000  // Commit every 1000 files
    private var isScanning = false
    private var shouldCancel = false

    // MARK: - Path Deduplication

    /// 对路径进行去重：移除被其他路径包含的子路径
    /// 例如：["/Users/eric", "/Users/eric/dev"] -> ["/Users/eric"]
    /// 这样可以避免重复扫描，提高性能
    private func deduplicatePaths(_ paths: [String]) -> [String] {
        guard paths.count > 1 else { return paths }

        // 按路径长度排序（短的在前），这样父目录会先被处理
        let sortedPaths = paths.sorted { $0.count < $1.count }
        var result: [String] = []

        for path in sortedPaths {
            // 规范化路径（移除尾部斜杠）
            let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path

            // 检查是否已经被某个已添加的路径包含
            let isSubpath = result.contains { parentPath in
                normalizedPath.hasPrefix(parentPath + "/") || normalizedPath == parentPath
            }

            if !isSubpath {
                result.append(normalizedPath)
            }
        }

        if result.count != paths.count {
            print("FileIndexer: Deduplicated paths from \(paths.count) to \(result.count)")
        }

        return result
    }

    // MARK: - Public API

    /// Scan directories and build index
    /// - Parameters:
    ///   - paths: Directories to scan
    ///   - excludedPaths: Paths to exclude
    ///   - excludedNames: Folder names to exclude (e.g., node_modules)
    ///   - excludedExtensions: File extensions to exclude
    ///   - progress: Progress callback (called on main thread)
    ///   - completion: Completion callback (called on main thread)
    func scan(
        paths: [String],
        excludedPaths: [String] = [],
        excludedNames: Set<String> = [],
        excludedExtensions: Set<String> = [],
        progress: ProgressCallback? = nil,
        completion: CompletionCallback? = nil
    ) {
        guard !isScanning else {
            print("FileIndexer: Already scanning")
            return
        }

        isScanning = true
        shouldCancel = false
        let startTime = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var totalScanned = 0
            var batch: [FileRecord] = []
            batch.reserveCapacity(self.batchSize)

            let excludedPathsSet = Set(excludedPaths)

            // 对路径进行去重：移除被其他路径包含的子路径
            // 例如：["/Users/eric", "/Users/eric/dev"] -> ["/Users/eric"]
            let deduplicatedPaths = self.deduplicatePaths(paths)

            for path in deduplicatedPaths {
                if self.shouldCancel { break }

                let url = URL(fileURLWithPath: path)
                guard
                    let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [
                            .isDirectoryKey,
                            .contentModificationDateKey,
                            .fileSizeKey,
                            .isApplicationKey,
                        ],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                else { continue }

                while let fileURL = enumerator.nextObject() as? URL {
                    if self.shouldCancel { break }

                    let filePath = fileURL.path

                    // Check excluded paths
                    if excludedPathsSet.contains(where: { filePath.hasPrefix($0) }) {
                        enumerator.skipDescendants()
                        continue
                    }

                    // Check excluded folder names
                    let fileName = fileURL.lastPathComponent
                    if excludedNames.contains(fileName) {
                        enumerator.skipDescendants()
                        continue
                    }

                    // Check excluded extensions
                    let ext = fileURL.pathExtension.lowercased()
                    if !ext.isEmpty && excludedExtensions.contains(ext) {
                        continue
                    }

                    // Get file attributes
                    guard let record = self.createFileRecord(from: fileURL) else { continue }

                    batch.append(record)
                    totalScanned += 1

                    // Report progress
                    if totalScanned % 500 == 0 {
                        let count = totalScanned
                        let currentPath = filePath
                        DispatchQueue.main.async {
                            progress?(count, currentPath)
                        }
                    }

                    // Commit batch
                    if batch.count >= self.batchSize {
                        let batchToInsert = batch
                        batch.removeAll(keepingCapacity: true)
                        self.database.insertBatch(batchToInsert)
                    }
                }
            }

            // Insert remaining batch
            if !batch.isEmpty {
                self.database.insertBatch(batch)
            }

            let duration = Date().timeIntervalSince(startTime)
            self.isScanning = false

            DispatchQueue.main.async {
                print(
                    "FileIndexer: Scan complete. Total: \(totalScanned), Duration: \(String(format: "%.2f", duration))s"
                )
                completion?(totalScanned, duration)
            }
        }
    }

    /// Scan only application directories (faster for app-only search)
    /// - Parameter paths: Application directories to scan (from SearchConfig.appScopes)
    func scanApplications(
        paths: [String],
        progress: ProgressCallback? = nil,
        completion: CompletionCallback? = nil
    ) {
        guard !isScanning else {
            print("FileIndexer: Already scanning")
            return
        }

        isScanning = true
        shouldCancel = false
        let startTime = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var totalScanned = 0
            var batch: [FileRecord] = []
            batch.reserveCapacity(500)

            // Also scan user Applications folder
            var allPaths = paths
            let userApps = NSHomeDirectory() + "/Applications"
            if FileManager.default.fileExists(atPath: userApps) {
                allPaths.append(userApps)
            }

            for path in allPaths {
                if self.shouldCancel { break }

                let url = URL(fileURLWithPath: path)
                guard
                    let contents = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )
                else { continue }

                for fileURL in contents {
                    if self.shouldCancel { break }

                    // Only process .app bundles
                    guard fileURL.pathExtension == "app" else { continue }

                    guard let record = self.createAppRecord(from: fileURL) else { continue }

                    batch.append(record)
                    totalScanned += 1

                    if totalScanned % 50 == 0 {
                        DispatchQueue.main.async {
                            progress?(totalScanned, fileURL.path)
                        }
                    }
                }
            }

            // Insert all apps
            if !batch.isEmpty {
                self.database.insertBatch(batch)
            }

            let duration = Date().timeIntervalSince(startTime)
            self.isScanning = false

            DispatchQueue.main.async {
                print(
                    "FileIndexer: App scan complete. Total: \(totalScanned), Duration: \(String(format: "%.3f", duration))s"
                )
                completion?(totalScanned, duration)
            }
        }
    }

    /// Cancel ongoing scan
    func cancel() {
        shouldCancel = true
    }

    /// Check if currently scanning
    var scanning: Bool {
        return isScanning
    }

    // MARK: - Private Helpers

    private func createFileRecord(from url: URL) -> FileRecord? {
        return Self.makeRecord(for: url)
    }

    private func createAppRecord(from url: URL) -> FileRecord? {
        return Self.makeRecord(for: url)
    }

    // MARK: - Record Building (共享)

    /// 统一构建 FileRecord：名称保留扩展名、app 用本地化显示名并过滤无图标的辅助程序、生成拼音。
    /// 全量扫描与 FSEvents 实时增量共用此入口，保证两条路径的记录语义一致
    /// （此前 SearchEngine 侧用 deletingPathExtension 剥掉扩展名、app 不取本地化名，
    /// 实时新增项与全量扫描项的名称 / 搜索行为不一致）。
    static func makeRecord(for url: URL) -> FileRecord? {
        let resourceValues = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isApplicationKey,
        ])

        let isDirectory = resourceValues?.isDirectory ?? false
        let isApp = url.pathExtension == "app"

        // Filter out apps without custom icons (system services like WiFiAgent, WindowManager)
        if isApp && !appHasCustomIcon(at: url.path) {
            return nil
        }

        let modifiedDate = resourceValues?.contentModificationDate
        let fileSize = resourceValues?.fileSize ?? 0

        // Get display name
        let name: String
        if isApp {
            // For apps, use localized display name (e.g., "微信" instead of "WeChat")
            name = FileManager.default.getAppDisplayName(at: url.path)
        } else {
            name = url.lastPathComponent
        }

        // Calculate pinyin for Chinese characters in display name
        var pinyinFull: String? = nil
        var pinyinAcronym: String? = nil

        if name.utf8.count != name.count {
            pinyinFull = name.pinyin.lowercased().replacingOccurrences(of: " ", with: "")
            pinyinAcronym = name.pinyinAcronym.lowercased()
        }

        return FileRecord(
            name: name,
            path: url.path,
            extension: url.pathExtension.lowercased(),
            isApp: isApp,
            isDirectory: isDirectory,
            pinyinFull: pinyinFull,
            pinyinAcronym: pinyinAcronym,
            modifiedDate: modifiedDate,
            fileSize: fileSize
        )
    }

    /// 枚举目录子树生成记录（FSEvents 目录 created 事件后补索引子文件用）。
    ///
    /// 目录「移入监控范围 / 从废纸篓恢复 / 粘贴整目录」时 FSEvents 只上报目录本身一条事件，
    /// 子文件不会再有事件，必须主动补扫。过滤规则与 `scan` 一致
    /// （排除路径 / 目录名 / 扩展名、隐藏文件、package 内部）。
    /// 不写数据库、不受 isScanning 守卫限制，可在后台线程调用。
    ///
    /// - Returns: 含根目录本身在内的记录数组；根目录被排除规则命中时返回空数组
    func collectSubtreeRecords(
        root: URL,
        excludedPaths: [String] = [],
        excludedNames: Set<String> = [],
        excludedExtensions: Set<String> = []
    ) -> [FileRecord] {
        let rootPath = root.path

        // 根目录本身命中排除规则则整体跳过
        let rootName = root.lastPathComponent
        if rootName.hasPrefix(".") { return [] }
        if excludedNames.contains(rootName) { return [] }
        if excludedPaths.contains(where: { rootPath.hasPrefix($0) }) { return [] }
        let rootExt = root.pathExtension.lowercased()
        if !rootExt.isEmpty && excludedExtensions.contains(rootExt) { return [] }

        var records: [FileRecord] = []
        if let rootRecord = Self.makeRecord(for: root) {
            records.append(rootRecord)
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isApplicationKey,
                ],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else { return records }

        while let fileURL = enumerator.nextObject() as? URL {
            let filePath = fileURL.path

            // Check excluded paths
            if excludedPaths.contains(where: { filePath.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }

            // Check excluded folder names
            let fileName = fileURL.lastPathComponent
            if excludedNames.contains(fileName) {
                enumerator.skipDescendants()
                continue
            }

            // Check excluded extensions
            let ext = fileURL.pathExtension.lowercased()
            if !ext.isEmpty && excludedExtensions.contains(ext) {
                continue
            }

            if let record = Self.makeRecord(for: fileURL) {
                records.append(record)
            }
        }

        return records
    }

    // MARK: - Helper Functions

    /// Check if an app has a custom icon defined in Info.plist
    /// Apps without icons (like system services in /System/Library/CoreServices/) return false
    private static func appHasCustomIcon(at path: String) -> Bool {
        let appName = (path as NSString).lastPathComponent

        // Filter out Electron/Chromium helper processes
        // These are auxiliary processes for apps like VSCode, Cursor, Chrome, etc.
        let helperPatterns = [
            " Helper",           // "Cursor Helper", "Chrome Helper"
            " Helper (GPU)",     // "Cursor Helper (GPU)"
            " Helper (Renderer)", // "Cursor Helper (Renderer)"
            " Helper (Plugin)",  // "Cursor Helper (Plugin)"
        ]

        for pattern in helperPatterns {
            if appName.contains(pattern) {
                return false
            }
        }

        let infoPlistPath = path + "/Contents/Info.plist"
        guard let infoPlistData = FileManager.default.contents(atPath: infoPlistPath),
            let plist = try? PropertyListSerialization.propertyList(
                from: infoPlistData, format: nil)
                as? [String: Any]
        else {
            return false
        }

        // Check for CFBundleIconFile or CFBundleIconName
        if let iconFile = plist["CFBundleIconFile"] as? String, !iconFile.isEmpty {
            return true
        }
        if let iconName = plist["CFBundleIconName"] as? String, !iconName.isEmpty {
            return true
        }

        return false
    }
}
