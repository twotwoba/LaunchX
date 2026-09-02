import Foundation
import SQLite3

/// SQLite database for persisting file index
/// Provides fast batch operations and efficient storage
final class IndexDatabase {
    static let shared = IndexDatabase()

    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.launchx.indexdb", qos: .userInitiated)

    // Prepared statements for performance
    private var insertStmt: OpaquePointer?
    private var deleteStmt: OpaquePointer?
    private var updateStmt: OpaquePointer?
    private var selectAllStmt: OpaquePointer?
    private var selectByPathStmt: OpaquePointer?

    // WAL 监控相关
    private var dbPath: String = ""
    private var checkpointCount: Int = 0
    private var lastCheckpointTime: Date = Date()

    var walOptimizationEnabled: Bool {
        return DiskWriteOptimizationSettings.shared.walOptimizationEnabled
    }

    private init() {
        openDatabase()
        createTables()
        prepareStatements()
    }

    deinit {
        finalizeStatements()
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let appFolder = appSupport.appendingPathComponent("LaunchX", isDirectory: true)

        // Create directory if needed
        try? fileManager.createDirectory(at: appFolder, withIntermediateDirectories: true)

        dbPath = appFolder.appendingPathComponent("file_index.db").path

        if sqlite3_open_v2(
            dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            != SQLITE_OK
        {
            print("IndexDatabase: Failed to open database at \(dbPath)")
            return
        }

        // Performance optimizations balanced for memory usage
        // Target: support 600k+ files without excessive memory pressure on 8GB Macs
        executeSQL("PRAGMA journal_mode = WAL")  // Write-Ahead Logging for concurrency
        executeSQL("PRAGMA wal_autocheckpoint = 10000")  // 磁盘写入优化：减少 checkpoint 频率（默认 1000）
        executeSQL("PRAGMA synchronous = NORMAL")  // Balance safety and speed
        executeSQL("PRAGMA cache_size = -64000")  // 64MB page cache (reduced from 128MB)
        executeSQL("PRAGMA temp_store = MEMORY")  // Temp tables in memory
        executeSQL("PRAGMA mmap_size = 268435456")  // 256MB memory-mapped I/O (reduced from 512MB)
        executeSQL("PRAGMA locking_mode = NORMAL")  // Allow multiple readers
        executeSQL("PRAGMA page_size = 4096")  // Optimize page size
        executeSQL("PRAGMA optimize")  // Auto-optimize query planner

        print("IndexDatabase: Opened database at \(dbPath)")
    }

    private func createTables() {
        let createTableSQL = """
                CREATE TABLE IF NOT EXISTS files (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    path TEXT NOT NULL UNIQUE,
                    extension TEXT,
                    is_app INTEGER DEFAULT 0,
                    is_directory INTEGER DEFAULT 0,
                    pinyin_full TEXT,
                    pinyin_acronym TEXT,
                    modified_date REAL,
                    indexed_date REAL DEFAULT (strftime('%s', 'now')),
                    file_size INTEGER DEFAULT 0
                );

                CREATE INDEX IF NOT EXISTS idx_name ON files(name);
                CREATE INDEX IF NOT EXISTS idx_path ON files(path);
                CREATE INDEX IF NOT EXISTS idx_extension ON files(extension);
                CREATE INDEX IF NOT EXISTS idx_is_app ON files(is_app);
                CREATE INDEX IF NOT EXISTS idx_pinyin_full ON files(pinyin_full);
                CREATE INDEX IF NOT EXISTS idx_pinyin_acronym ON files(pinyin_acronym);
                CREATE INDEX IF NOT EXISTS idx_modified_date ON files(modified_date);
            """

        executeSQL(createTableSQL)
    }

    private func prepareStatements() {
        let insertSQL = """
                INSERT OR REPLACE INTO files
                (name, path, extension, is_app, is_directory, pinyin_full, pinyin_acronym, modified_date, file_size)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil)

        let deleteSQL = "DELETE FROM files WHERE path = ?"
        sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil)

        let updateSQL = """
                UPDATE files SET name = ?, extension = ?, modified_date = ?, file_size = ?
                WHERE path = ?
            """
        sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil)

        let selectAllSQL = "SELECT * FROM files"
        sqlite3_prepare_v2(db, selectAllSQL, -1, &selectAllStmt, nil)

        let selectByPathSQL = "SELECT * FROM files WHERE path = ?"
        sqlite3_prepare_v2(db, selectByPathSQL, -1, &selectByPathStmt, nil)
    }

    private func finalizeStatements() {
        sqlite3_finalize(insertStmt)
        sqlite3_finalize(deleteStmt)
        sqlite3_finalize(updateStmt)
        sqlite3_finalize(selectAllStmt)
        sqlite3_finalize(selectByPathStmt)
    }

    @discardableResult
    private func executeSQL(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("IndexDatabase: SQL Error - \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
            return false
        }
        return true
    }

    // MARK: - Public API

    /// Insert multiple file records in a single transaction (very fast)
    func insertBatch(_ records: [FileRecord], completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let stmt = self.insertStmt else {
                completion?(false)
                return
            }

            self.executeSQL("BEGIN TRANSACTION")

            for record in records {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                sqlite3_bind_text(stmt, 1, record.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, record.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, record.extension, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 4, record.isApp ? 1 : 0)
                sqlite3_bind_int(stmt, 5, record.isDirectory ? 1 : 0)
                sqlite3_bind_text(stmt, 6, record.pinyinFull, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 7, record.pinyinAcronym, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 8, record.modifiedDate?.timeIntervalSince1970 ?? 0)
                sqlite3_bind_int64(stmt, 9, Int64(record.fileSize))

                if sqlite3_step(stmt) != SQLITE_DONE {
                    print("IndexDatabase: Failed to insert record: \(record.path)")
                }
            }

            self.executeSQL("COMMIT")

            DispatchQueue.main.async {
                completion?(true)
            }
        }
    }

    /// Insert a single file record
    func insert(_ record: FileRecord) {
        insertBatch([record])
    }

    /// Delete records by paths
    func deleteBatch(_ paths: [String], completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, let stmt = self.deleteStmt else {
                completion?(false)
                return
            }

            self.executeSQL("BEGIN TRANSACTION")

            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }

            self.executeSQL("COMMIT")

            DispatchQueue.main.async {
                completion?(true)
            }
        }
    }

    /// Delete a single record by path
    func delete(path: String) {
        deleteBatch([path])
    }

    /// Delete all records and reset database
    func deleteAll(completion: ((Bool) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            let success = self?.executeSQL("DELETE FROM files") ?? false
            self?.executeSQL("VACUUM")  // Reclaim space

            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }

    /// 删除路径本身及其全部子路径记录（目录删除的级联语义）。
    ///
    /// 利用 idx_path 的 B-tree 范围扫描：所有以 "path/" 开头的字符串恰好落在
    /// [path + "/", path 去掉末尾 '/' 换成 '0') 区间内（'/' (0x2F) 的后继字节是 '0' (0x30)），
    /// 避免 LIKE 方案需要转义 `%` / `_` 通配符的问题，且能走索引。
    ///
    /// - Parameters:
    ///   - path: 要删除的文件或目录路径
    ///   - completion: Callback with deleted count
    func deleteSubtree(atPath path: String, completion: ((Int) -> Void)? = nil) {
        dbQueue.async { [weak self] in
            guard let self = self, !path.isEmpty else {
                DispatchQueue.main.async { completion?(0) }
                return
            }

            let prefix = path.hasSuffix("/") && path.count > 1
                ? String(path.dropLast()) + "/" : path + "/"
            // 上界：前缀去掉末尾 '/'（0x2F）后加 '0'（0x30），覆盖所有以 prefix 开头的字符串
            let upperBound = String(prefix.dropLast()) + "0"

            var deletedCount = 0
            var stmt: OpaquePointer?
            let sql = "DELETE FROM files WHERE path = ?1 OR (path >= ?2 AND path < ?3)"

            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt {
                sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, prefix, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, upperBound, -1, SQLITE_TRANSIENT)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    deletedCount = Int(sqlite3_changes(self.db))
                }
                sqlite3_finalize(stmt)
            } else {
                print("IndexDatabase: deleteSubtree failed to prepare statement for \(path)")
            }

            DispatchQueue.main.async {
                completion?(deletedCount)
            }
        }
    }

    /// Load all records from database
    func loadAll(completion: @escaping ([FileRecord]) -> Void) {
        dbQueue.async { [weak self] in
            guard let self = self, let stmt = self.selectAllStmt else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var records: [FileRecord] = []
            records.reserveCapacity(100000)  // Pre-allocate for performance

            sqlite3_reset(stmt)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let record = self.recordFromStatement(stmt)
                records.append(record)
            }

            DispatchQueue.main.async {
                completion(records)
            }
        }
    }

    /// Synchronously load all records
    func loadAllSync() -> [FileRecord] {
        var records: [FileRecord] = []

        dbQueue.sync { [weak self] in
            guard let self = self, let stmt = self.selectAllStmt else { return }

            sqlite3_reset(stmt)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let record = self.recordFromStatement(stmt)
                records.append(record)
            }
        }

        return records
    }

    /// Load records in batches for optimized startup performance
    /// 分批加载记录，优化启动性能
    func loadBatch(offset: Int, limit: Int) -> [FileRecord] {
        var records: [FileRecord] = []
        records.reserveCapacity(limit)

        dbQueue.sync { [weak self] in
            guard let self = self else { return }

            var stmt: OpaquePointer?
            let sql = "SELECT * FROM files ORDER BY id LIMIT ? OFFSET ?"

            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let stmt = stmt {
                    sqlite3_bind_int(stmt, 1, Int32(limit))
                    sqlite3_bind_int(stmt, 2, Int32(offset))

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let record = self.recordFromStatement(stmt)
                        records.append(record)
                    }

                    sqlite3_finalize(stmt)
                }
            }
        }

        return records
    }

    /// Check if a path exists in database
    func exists(path: String) -> Bool {
        var result = false

        dbQueue.sync { [weak self] in
            guard let self = self, let stmt = self.selectByPathStmt else { return }

            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)

            result = sqlite3_step(stmt) == SQLITE_ROW
        }

        return result
    }

    /// Get database statistics
    func getStatistics() -> (totalCount: Int, appsCount: Int, filesCount: Int) {
        var total = 0
        var apps = 0
        var files = 0

        dbQueue.sync { [weak self] in
            guard let self = self else { return }

            var stmt: OpaquePointer?

            // Total count
            if sqlite3_prepare_v2(self.db, "SELECT COUNT(*) FROM files", -1, &stmt, nil)
                == SQLITE_OK
            {
                if let stmt = stmt {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        total = Int(sqlite3_column_int(stmt, 0))
                    }
                    sqlite3_finalize(stmt)
                }
            }

            // Apps count
            if sqlite3_prepare_v2(
                self.db, "SELECT COUNT(*) FROM files WHERE is_app = 1", -1, &stmt, nil) == SQLITE_OK
            {
                if let stmt = stmt {
                    if sqlite3_step(stmt) == SQLITE_ROW {
                        apps = Int(sqlite3_column_int(stmt, 0))
                    }
                    sqlite3_finalize(stmt)
                }
            }

            files = total - apps
        }

        return (total, apps, files)
    }

    // MARK: - WAL Checkpoint 管理

    /// 获取 WAL 文件大小（字节）
    ///
    /// WAL (Write-Ahead Logging) 是 SQLite 的日志模式，所有写入操作先记录到 WAL 文件，
    /// 定期通过 checkpoint 操作合并到主数据库文件。
    ///
    /// - Returns: WAL 文件大小，如果文件不存在返回 0
    func getWALFileSize() -> Int64 {
        let walPath = dbPath + "-wal"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: walPath),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    /// 获取主数据库文件大小（字节）
    func getDatabaseFileSize() -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    /// 获取 WAL 统计信息
    func getWALStatistics() -> (walSize: Int64, dbSize: Int64, checkpointCount: Int) {
        return (getWALFileSize(), getDatabaseFileSize(), checkpointCount)
    }

    /// 执行手动 checkpoint
    ///
    /// **SQLite WAL 优化的核心功能**
    ///
    /// ## 原理
    /// Checkpoint 将 WAL 文件中的更改合并到主数据库文件。
    /// 通过调整 checkpoint 频率，可以显著减少磁盘写入次数。
    ///
    /// ## Checkpoint 模式
    /// - **PASSIVE**: 被动模式，不阻塞读写，可能无法完全清空 WAL
    /// - **FULL**: 完整模式，等待所有读者完成，确保 WAL 被清空
    /// - **RESTART**: 重启模式，清空 WAL 并重置
    /// - **TRUNCATE**: 截断模式，清空 WAL 并截断文件大小
    ///
    /// ## 优化策略
    /// 1. 将 wal_autocheckpoint 从 1000 提升到 10000 页
    ///    - 减少自动 checkpoint 频率 90%
    ///    - 允许 WAL 文件增长到约 40 MB
    /// 2. 应用空闲时（5分钟）执行 PASSIVE checkpoint
    ///    - 利用空闲时间合并数据，不影响性能
    /// 3. WAL 文件超过 100 MB 时强制 TRUNCATE checkpoint
    ///    - 防止 WAL 文件无限增长
    ///
    /// ## 权衡
    /// - **WAL 文件增大**：从 4 MB 增长到 40-100 MB
    /// - **崩溃恢复时间**：WAL 越大，恢复时间越长（但仍在毫秒级）
    /// - **磁盘空间**：需要额外 40-100 MB 空间
    /// - **优化效果**：预期减少 checkpoint 相关写入 60-70%
    ///
    /// ## 配置
    /// 可通过 `DiskWriteOptimizationSettings.walOptimizationEnabled` 开关控制
    ///
    /// - Parameter mode: checkpoint 模式（PASSIVE, FULL, RESTART, TRUNCATE）
    /// - Returns: 是否成功
    @discardableResult
    func performCheckpoint(mode: String = "PASSIVE") -> Bool {
        guard walOptimizationEnabled else {
            print("[IndexDatabase] WAL optimization disabled, skipping manual checkpoint")
            return false
        }

        var success = false

        // 使用异步方式避免死锁
        dbQueue.async { [weak self] in
            guard let self = self else { return }

            // 记录 checkpoint 前的 WAL 大小
            let walSizeBefore = self.getWALFileSize()

            // 执行 checkpoint
            let sql = "PRAGMA wal_checkpoint(\(mode))"
            if self.executeSQL(sql) {
                self.checkpointCount += 1
                self.lastCheckpointTime = Date()

                let walSizeAfter = self.getWALFileSize()
                let bytesWritten = walSizeBefore - walSizeAfter

                // 记录磁盘写入量（checkpoint将WAL合并到主库）
                if bytesWritten > 0 {
                    DiskWriteMonitor.shared.recordWrite(bytes: bytesWritten)
                }

                print("[IndexDatabase] Checkpoint completed: \(walSizeBefore) -> \(walSizeAfter) bytes, total checkpoints: \(self.checkpointCount)")
                success = true
            } else {
                print("[IndexDatabase] Checkpoint failed")
            }
        }
        return success
    }

    /// 检查并在需要时执行强制 checkpoint
    /// 当 WAL 文件超过 100 MB 时触发
    func checkAndForceCheckpoint() {
        guard walOptimizationEnabled else { return }

        let walSize = getWALFileSize()
        let maxWALSize: Int64 = 100 * 1024 * 1024  // 100 MB

        if walSize > maxWALSize {
            print("[IndexDatabase] WAL file exceeds 100 MB (\(walSize) bytes), forcing checkpoint")
            // 使用 TRUNCATE 模式强制截断 WAL 文件
            performCheckpoint(mode: "TRUNCATE")
        }
    }

    /// 应用空闲时的定期 checkpoint（5 分钟间隔调用）
    func idleCheckpoint() {
        guard walOptimizationEnabled else { return }

        // 检查距离上次 checkpoint 的时间
        let timeSinceLastCheckpoint = Date().timeIntervalSince(lastCheckpointTime)
        if timeSinceLastCheckpoint >= 300 {  // 5 分钟
            let walSize = getWALFileSize()
            if walSize > 1024 * 1024 {  // 只有 WAL 超过 1 MB 才执行
                print("[IndexDatabase] Performing idle checkpoint, WAL size: \(walSize) bytes")
                performCheckpoint(mode: "PASSIVE")
            }
        }
    }

    /// 重置 checkpoint 计数器
    func resetCheckpointCount() {
        checkpointCount = 0
        lastCheckpointTime = Date()
    }

    private func recordFromStatement(_ stmt: OpaquePointer) -> FileRecord {
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let path = String(cString: sqlite3_column_text(stmt, 2))

        var ext: String? = nil
        if let extPtr = sqlite3_column_text(stmt, 3) {
            ext = String(cString: extPtr)
        }

        let isApp = sqlite3_column_int(stmt, 4) == 1
        let isDirectory = sqlite3_column_int(stmt, 5) == 1

        var pinyinFull: String? = nil
        if let ptr = sqlite3_column_text(stmt, 6) {
            pinyinFull = String(cString: ptr)
        }

        var pinyinAcronym: String? = nil
        if let ptr = sqlite3_column_text(stmt, 7) {
            pinyinAcronym = String(cString: ptr)
        }

        let modifiedTimestamp = sqlite3_column_double(stmt, 8)
        let modifiedDate =
            modifiedTimestamp > 0 ? Date(timeIntervalSince1970: modifiedTimestamp) : nil

        let fileSize = Int(sqlite3_column_int64(stmt, 9))

        return FileRecord(
            name: name,
            path: path,
            extension: ext,
            isApp: isApp,
            isDirectory: isDirectory,
            pinyinFull: pinyinFull,
            pinyinAcronym: pinyinAcronym,
            modifiedDate: modifiedDate,
            fileSize: fileSize
        )
    }
}

// MARK: - File Record Model

/// Represents a file record in the index database
public struct FileRecord {
    public let name: String
    public let path: String
    public let `extension`: String?
    public let isApp: Bool
    public let isDirectory: Bool
    public let pinyinFull: String?
    public let pinyinAcronym: String?
    public let modifiedDate: Date?
    public let fileSize: Int

    public init(
        name: String,
        path: String,
        extension: String? = nil,
        isApp: Bool = false,
        isDirectory: Bool = false,
        pinyinFull: String? = nil,
        pinyinAcronym: String? = nil,
        modifiedDate: Date? = nil,
        fileSize: Int = 0
    ) {
        self.name = name
        self.path = path
        self.extension = `extension`
        self.isApp = isApp
        self.isDirectory = isDirectory
        self.pinyinFull = pinyinFull
        self.pinyinAcronym = pinyinAcronym
        self.modifiedDate = modifiedDate
        self.fileSize = fileSize
    }
}

// MARK: - SQLite Transient

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
