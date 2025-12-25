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

    // MARK: - Localized Name Helper

    /// Get localized app name (supports Chinese names like "微信", "企业微信", "活动监视器")
    private func getLocalizedAppName(at appPath: String) -> String? {
        let fm = FileManager.default

        // Method 1: Check InfoPlist.strings in Chinese localization directories
        let resourcesPath = appPath + "/Contents/Resources"
        let lprojDirs = ["zh-Hans.lproj", "zh_CN.lproj", "zh-Hant.lproj", "zh_TW.lproj"]

        for lproj in lprojDirs {
            let stringsPath = resourcesPath + "/" + lproj + "/InfoPlist.strings"
            guard fm.fileExists(atPath: stringsPath),
                let data = fm.contents(atPath: stringsPath)
            else { continue }

            // Try as property list first
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: String],
                let displayName = plist["CFBundleDisplayName"] ?? plist["CFBundleName"]
            {
                return displayName
            }

            // Try reading as UTF-16 (common encoding for .strings files)
            if let str = String(data: data, encoding: .utf16) {
                let pattern = "\"CFBundleDisplayName\"\\s*=\\s*\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: pattern),
                    let match = regex.firstMatch(
                        in: str, range: NSRange(str.startIndex..., in: str)),
                    let range = Range(match.range(at: 1), in: str)
                {
                    return String(str[range])
                }

                // Try CFBundleName if CFBundleDisplayName not found
                let namePattern = "\"CFBundleName\"\\s*=\\s*\"([^\"]+)\""
                if let regex = try? NSRegularExpression(pattern: namePattern),
                    let match = regex.firstMatch(
                        in: str, range: NSRange(str.startIndex..., in: str)),
                    let range = Range(match.range(at: 1), in: str)
                {
                    return String(str[range])
                }
            }
        }

        // Method 2: Check Info.plist CFBundleDisplayName (some apps like 企业微信 use this)
        let infoPlistPath = appPath + "/Contents/Info.plist"
        if let infoPlistData = fm.contents(atPath: infoPlistPath),
            let plist = try? PropertyListSerialization.propertyList(
                from: infoPlistData, format: nil) as? [String: Any]
        {
            if let displayName = plist["CFBundleDisplayName"] as? String,
                displayName.hasMultiByteCharacters
            {
                return displayName
            }
        }

        // Method 3: Use Spotlight metadata (for system apps like Activity Monitor -> 活动监视器)
        if let mdItem = MDItemCreate(nil, appPath as CFString),
            let displayName = MDItemCopyAttribute(mdItem, kMDItemDisplayName) as? String,
            displayName.hasMultiByteCharacters
        {
            return displayName
        }

        return nil
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

            for path in paths {
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
            name =
                getLocalizedAppName(at: url.path)
                ?? FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        } else {
            name = url.lastPathComponent
        }

        // Get the actual filename for matching (e.g., "WeChat" for WeChat.app)
        // TODO: 后续用于支持按文件名搜索（如搜索 "wechat" 找到 "微信"）
        _ = url.deletingPathExtension().lastPathComponent

        // Calculate pinyin for Chinese characters in display name
        var pinyinFull: String? = nil
        var pinyinAcronym: String? = nil

        if name.hasMultiByteCharacters {
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

    private func createAppRecord(from url: URL) -> FileRecord? {
        // Filter out apps without custom icons (system services like WiFiAgent, WindowManager)
        if !appHasCustomIcon(at: url.path) {
            return nil
        }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])

        // Get localized display name (prefer Chinese localization, fallback to system display name)
        let name =
            getLocalizedAppName(at: url.path)
            ?? FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")

        // Calculate pinyin for Chinese characters
        var pinyinFull: String? = nil
        var pinyinAcronym: String? = nil

        if name.hasMultiByteCharacters {
            pinyinFull = name.pinyin.lowercased().replacingOccurrences(of: " ", with: "")
            pinyinAcronym = name.pinyinAcronym.lowercased()
        }

        return FileRecord(
            name: name,
            path: url.path,
            extension: "app",
            isApp: true,
            isDirectory: true,
            pinyinFull: pinyinFull,
            pinyinAcronym: pinyinAcronym,
            modifiedDate: resourceValues?.contentModificationDate,
            fileSize: 0
        )
    }
}
