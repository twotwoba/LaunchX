import XCTest

@testable import LaunchX

/// 配置快照服务:收录/刷新/对比/恢复/备份(全部在 temporaryDirectory,严禁触真实 ~)
final class ToolboxSnapshotServiceTests: XCTestCase {
    private var workDir: URL!
    private var store: ToolboxStore!
    private var service: SnapshotService!

    override func setUpWithError() throws {
        // 每个用例独立的临时目录,绝不触碰真实用户目录
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        store = ToolboxStore(
            directory: workDir.appendingPathComponent("toolbox", isDirectory: true),
            keychain: InMemoryKeychain())
        service = SnapshotService(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - 收录

    func testCaptureCopiesContentAndComputesMeta() throws {
        let source = workDir.appendingPathComponent(".zshrc")
        try "export EDITOR=vim".write(to: source, atomically: true, encoding: .utf8)

        let item = try awaitOrBlock { try await self.service.capture(sourceURL: source) }

        XCTAssertEqual(item.kind, .configSnapshot)
        XCTAssertEqual(item.snapshotMeta?.fileNameOnDisk, ".zshrc")
        let content = try Data(contentsOf: source)
        XCTAssertEqual(item.snapshotMeta?.sha256, SnapshotService.sha256Hex(of: content))
        XCTAssertEqual(item.snapshotMeta?.byteSize, content.count)
        // 快照文件已落盘且内容一致
        let snapshotData = store.snapshotData(for: item)
        XCTAssertEqual(snapshotData, content)
        // 源路径存 home 相对形式(temp 目录不在 home 下 → 存绝对路径)
        XCTAssertEqual(item.sourcePath, source.path)
    }

    func testCaptureRejectsDirectory() throws {
        let dir = workDir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try awaitOrBlock { try await self.service.capture(sourceURL: dir) })
    }

    func testCaptureRejectsOversized() throws {
        let big = workDir.appendingPathComponent("big.txt")
        let data = Data(count: SnapshotService.maxSnapshotBytes + 1)
        try data.write(to: big)
        XCTAssertThrowsError(try awaitOrBlock { try await self.service.capture(sourceURL: big) })
    }

    // MARK: - 刷新

    func testRefreshUpdatesSnapshotKeepingIdentity() throws {
        let source = workDir.appendingPathComponent(".gitconfig")
        try "[user]\n\tname = a".write(to: source, atomically: true, encoding: .utf8)
        let original = try awaitOrBlock { try await self.service.capture(sourceURL: source) }

        // 修改源文件后刷新
        try "[user]\n\tname = b".write(to: source, atomically: true, encoding: .utf8)
        let refreshed = try awaitOrBlock { try await self.service.refresh(item: original) }

        XCTAssertEqual(refreshed.id, original.id, "刷新应保留条目 id")
        XCTAssertEqual(refreshed.createdAt, original.createdAt)
        XCTAssertNotEqual(refreshed.snapshotMeta?.sha256, original.snapshotMeta?.sha256)
        let newData = try Data(contentsOf: source)
        XCTAssertEqual(store.snapshotData(for: refreshed), newData)
    }

    func testRefreshThrowsWhenSourceMissing() throws {
        let source = workDir.appendingPathComponent("ghost.txt")
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: source) }
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try awaitOrBlock { try await self.service.refresh(item: item) })
    }

    // MARK: - 对比

    func testAnalyzeTargetMissing() throws {
        // 真实收录一份快照,再把 sourcePath 指向不存在的路径(模拟新机未装)
        let source = workDir.appendingPathComponent(".zshrc")
        try "export PATH=~/bin".write(to: source, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: source) }

        var migrated = item
        migrated.sourcePath = "~/definitely-not-exists-\(UUID().uuidString)"
        XCTAssertEqual(service.analyze(item: migrated), .targetMissing)
    }

    func testAnalyzeIdentical() throws {
        let target = workDir.appendingPathComponent("target.conf")
        try "key=value".write(to: target, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: target) }
        XCTAssertEqual(service.analyze(item: item), .identical)
    }

    func testAnalyzeDiffersByContent() throws {
        let target = workDir.appendingPathComponent("target2.conf")
        try "key=value".write(to: target, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: target) }
        // 同尺寸不同内容
        try "key=WALUE".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.analyze(item: item), .differs)
    }

    func testAnalyzeDiffersBySize() throws {
        let target = workDir.appendingPathComponent("target3.conf")
        try "short".write(to: target, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: target) }
        try "much-longer-content".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(service.analyze(item: item), .differs)
    }

    // MARK: - 恢复

    func testRestoreWritesWhenTargetMissing() throws {
        let source = workDir.appendingPathComponent("src.conf")
        try "snapshot-content".write(to: source, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: source) }

        // 改 sourcePath 指向新位置(模拟新机)
        var migrated = item
        migrated.sourcePath = workDir.appendingPathComponent("new-location.conf").path
        let outcome = try awaitOrBlock { try await self.service.restore(item: migrated) }

        guard case .written = outcome else {
            return XCTFail("期望 .written,实际 \(outcome)")
        }
        let restored = try String(contentsOf: migrated.resolvedSourceURL!, encoding: .utf8)
        XCTAssertEqual(restored, "snapshot-content")
    }

    func testRestoreDiffersWritesBackup() throws {
        let target = workDir.appendingPathComponent("live.conf")
        try "old-content".write(to: target, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: target) }
        try "changed-content".write(to: target, atomically: true, encoding: .utf8)

        let outcome = try awaitOrBlock { try await self.service.restore(item: item) }

        guard case .backupWritten(let backupPath) = outcome else {
            return XCTFail("期望 .backupWritten,实际 \(outcome)")
        }
        // 目标已还原为快照内容(收录时的 "old-content")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old-content")
        // 备份文件存在且是覆盖前内容
        let backupContent = try String(contentsOfFile: backupPath, encoding: .utf8)
        XCTAssertEqual(backupContent, "changed-content")
        XCTAssertTrue(backupPath.contains(".launchx.bak-"))
    }

    func testRestoreIdenticalSkips() throws {
        let target = workDir.appendingPathComponent("same.conf")
        try "identical".write(to: target, atomically: true, encoding: .utf8)
        let item = try awaitOrBlock { try await self.service.capture(sourceURL: target) }
        let outcome = try awaitOrBlock { try await self.service.restore(item: item) }
        XCTAssertEqual(outcome, .skippedIdentical)
    }

    // MARK: - Hash

    func testSha256Hex() {
        // "abc" 的 SHA256 标准测试向量
        let hex = SnapshotService.sha256Hex(of: Data("abc".utf8))
        XCTAssertEqual(
            hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - 辅助

    /// 等待 async 表达式完成(快照核心走后台队列)
    private func awaitOrBlock<T: Sendable>(_ work: @escaping () async throws -> T) throws -> T {
        let expectation = expectation(description: "async snapshot work")
        nonisolated(unsafe) var result: Result<T, Error>?
        Task.detached {
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        return try XCTUnwrap(result).get()
    }
}
