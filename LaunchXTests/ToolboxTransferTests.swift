import XCTest

@testable import LaunchX

/// 百宝箱导出/导入:文件结构往返、激活码默认排除、快照 base64 往返、导入落盘
/// (全部注入临时目录 store 与 InMemoryKeychain,不触真实数据)
final class ToolboxTransferTests: XCTestCase {
    private var workDir: URL!
    private var store: ToolboxStore!
    private var keychain: InMemoryKeychain!
    private var service: ToolboxTransferService!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        store = ToolboxStore(directory: workDir, keychain: InMemoryKeychain())
        keychain = InMemoryKeychain()
        service = ToolboxTransferService(store: store, keychain: keychain)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - 导出结构

    /// 默认导出:包含条目与快照内容,但【绝不】携带激活码明文
    func testBuildExportExcludesLicenseSecretsByDefault() throws {
        let snapshotFile = workDir.appendingPathComponent(".zshrc")
        try "export PATH=~/bin".write(to: snapshotFile, atomically: true, encoding: .utf8)
        let snapshotItem = try awaitCapture(url: snapshotFile)

        let licenseItem = ToolboxItem.license(name: "Parallels", account: "a@b.com")
        keychain.set(
            "SECRET-KEY", service: KeychainStore.service,
            account: KeychainStore.account(for: licenseItem.id))
        try store.upsert(licenseItem)
        let linkItem = ToolboxItem.toolLink(name: "Raycast", url: "https://raycast.com")
        try store.upsert(linkItem)

        let export = ToolboxTransferService.buildExport(
            items: [snapshotItem, licenseItem, linkItem],
            includesLicenses: false,
            store: store,
            keychain: keychain,
            appVersion: "1.0.0")

        XCTAssertEqual(export.items.count, 3)
        XCTAssertEqual(export.snapshots?.count, 1, "快照内容应随文件携带")
        XCTAssertNil(export.licenseSecrets, "未勾选时绝不携带激活码明文")
        XCTAssertFalse(export.includesLicenses)
    }

    /// 勾选包含时:激活码明文以 base64 随文件
    func testBuildExportIncludesLicenseSecretsWhenRequested() throws {
        let licenseItem = ToolboxItem.license(name: "Parallels")
        keychain.set(
            "SECRET-KEY", service: KeychainStore.service,
            account: KeychainStore.account(for: licenseItem.id))
        try store.upsert(licenseItem)

        let export = ToolboxTransferService.buildExport(
            items: [licenseItem],
            includesLicenses: true,
            store: store,
            keychain: keychain,
            appVersion: nil)

        XCTAssertTrue(export.includesLicenses)
        XCTAssertEqual(export.licenseSecrets?.count, 1)
        let payload = export.licenseSecrets?.first
        XCTAssertEqual(
            Data(base64Encoded: payload?.secretBase64 ?? ""), Data("SECRET-KEY".utf8))
    }

    /// 编码 → 解码往返(导入端解析)
    func testExportRoundTripDecode() throws {
        let licenseItem = ToolboxItem.license(name: "Sketch")
        keychain.set(
            "K1", service: KeychainStore.service,
            account: KeychainStore.account(for: licenseItem.id))
        let export = ToolboxTransferService.buildExport(
            items: [licenseItem], includesLicenses: true, store: store, keychain: keychain,
            appVersion: "2.0")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)

        let decoded = ToolboxExportFile.decode(from: data)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.items.count, 1)
        XCTAssertEqual(decoded?.items.first?.kind, .license)
        XCTAssertEqual(decoded?.includesLicenses, true)
        XCTAssertEqual(decoded?.licenseSecrets?.count, 1)
    }

    // MARK: - 导入落盘

    /// 导入往返:条目写入清单、快照落 snapshots 目录、激活码回 Keychain
    /// (importFromFile 本体含 NSAlert 策略弹窗,单测验证其底层落盘逻辑的等价路径)
    func testExportImportRoundTripAcrossStores() throws {
        // 源端:快照 + 带明文的激活码
        let sourceConfig = workDir.appendingPathComponent(".gitconfig")
        try "[core]\n\tautocrlf = false".write(to: sourceConfig, atomically: true, encoding: .utf8)
        let originStore = ToolboxStore(
            directory: workDir.appendingPathComponent("origin", isDirectory: true),
            keychain: InMemoryKeychain())
        let originService = SnapshotService(store: originStore)
        let snapshotItem = try awaitCapture(url: sourceConfig, service: originService)
        try originStore.upsert(snapshotItem)

        let licenseItem = ToolboxItem.license(name: "Parallels")
        keychain.set(
            "LIC-1", service: KeychainStore.service,
            account: KeychainStore.account(for: licenseItem.id))
        try originStore.upsert(licenseItem)

        let export = ToolboxTransferService.buildExport(
            items: [snapshotItem, licenseItem],
            includesLicenses: true,
            store: originStore,
            keychain: keychain,
            appVersion: nil)

        // 文件往返:编码 → 解码(模拟两台机器间传输)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fileData = try encoder.encode(export)
        let imported = try XCTUnwrap(ToolboxExportFile.decode(from: fileData))

        // 目标端:合并(空清单)→ 落盘快照 → 回填激活码
        var current: [ToolboxItem] = []
        let report = ToolboxTransferService.merge(
            into: &current, incoming: imported.items, policy: .overwriteExisting)
        var manifest = store.loadManifest()
        manifest.items = current
        try store.saveManifest(manifest)

        XCTAssertEqual(store.loadManifest().items.count, 2)

        for payload in imported.snapshots ?? [] {
            let finalID = try XCTUnwrap(report.idMap[payload.itemId], "快照条目应有 id 映射")
            let content = try XCTUnwrap(Data(base64Encoded: payload.contentBase64), "快照 base64 应可解码")
            try store.writeSnapshotData(
                content, itemID: finalID,
                fileNameOnDisk: ToolboxStore.sanitizedFileName(from: payload.fileName))
        }
        for secretPayload in imported.licenseSecrets ?? [] {
            let finalID = try XCTUnwrap(report.idMap[secretPayload.itemId])
            let secret = try XCTUnwrap(
                String(data: Data(base64Encoded: secretPayload.secretBase64) ?? Data(), encoding: .utf8))
            XCTAssertTrue(
                keychain.set(
                    secret, service: KeychainStore.service,
                    account: KeychainStore.account(for: finalID)))
        }

        // 断言:快照文件与激活码在目标端完整恢复
        let restoredSnapshot = try XCTUnwrap(store.items(of: .configSnapshot).first)
        XCTAssertTrue(store.snapshotFileExists(for: restoredSnapshot))
        let restoredLicense = try XCTUnwrap(store.items(of: .license).first)
        XCTAssertEqual(
            keychain.get(
                service: KeychainStore.service,
                account: KeychainStore.account(for: restoredLicense.id)),
            "LIC-1")
    }

    /// 导出文件损坏时解码返回 nil(或容错解码出部分条目),不崩溃
    func testDecodeInvalidDataDoesNotCrash() {
        XCTAssertNil(ToolboxExportFile.decode(from: Data("not json".utf8)))
    }

    // MARK: - 辅助

    private func awaitCapture(url: URL, service captureService: SnapshotService? = nil) throws
        -> ToolboxItem
    {
        let target = captureService ?? SnapshotService(store: store)
        let expectation = expectation(description: "capture")
        nonisolated(unsafe) var result: Result<ToolboxItem, Error>?
        Task.detached {
            do {
                result = .success(try await target.capture(sourceURL: url))
            } catch {
                result = .failure(error)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
        return try XCTUnwrap(result).get()
    }
}
