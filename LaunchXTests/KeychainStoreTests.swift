import XCTest

@testable import LaunchX

/// Keychain 封装:InMemory 实现的 set/get/覆盖/删除 + ToolboxStore 删除条目时同步清密钥
/// (绝不触碰真实 Keychain,真实 SecItem 实现不做单测)
final class KeychainStoreTests: XCTestCase {

    // MARK: - InMemoryKeychain 基础语义

    func testSetThenGet() {
        let keychain = InMemoryKeychain()
        XCTAssertTrue(keychain.set("secret-1", service: "svc", account: "acc-1"))
        XCTAssertEqual(keychain.get(service: "svc", account: "acc-1"), "secret-1")
    }

    func testSetOverwritesExisting() {
        let keychain = InMemoryKeychain()
        keychain.set("old", service: "svc", account: "acc")
        XCTAssertTrue(keychain.set("new", service: "svc", account: "acc"))
        XCTAssertEqual(keychain.get(service: "svc", account: "acc"), "new")
    }

    func testDeleteRemoves() {
        let keychain = InMemoryKeychain()
        keychain.set("secret", service: "svc", account: "acc")
        XCTAssertTrue(keychain.delete(service: "svc", account: "acc"))
        XCTAssertNil(keychain.get(service: "svc", account: "acc"))
    }

    func testGetMissingReturnsNil() {
        let keychain = InMemoryKeychain()
        XCTAssertNil(keychain.get(service: "svc", account: "nobody"))
    }

    func testKeysAreIsolatedByServiceAndAccount() {
        let keychain = InMemoryKeychain()
        keychain.set("a", service: "svc-1", account: "acc")
        keychain.set("b", service: "svc-2", account: "acc")
        keychain.set("c", service: "svc-1", account: "acc-2")
        XCTAssertEqual(keychain.get(service: "svc-1", account: "acc"), "a")
        XCTAssertEqual(keychain.get(service: "svc-2", account: "acc"), "b")
        XCTAssertEqual(keychain.get(service: "svc-1", account: "acc-2"), "c")
    }

    // MARK: - KeychainStore 便捷入口映射

    func testKeychainStoreAccountMapping() {
        let id = UUID()
        XCTAssertEqual(KeychainStore.account(for: id), id.uuidString)
    }

    // MARK: - ToolboxStore 删除条目同步清密钥

    func testStoreDeleteClearsLicenseSecret() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = InMemoryKeychain()
        let store = ToolboxStore(directory: dir, keychain: keychain)

        let item = ToolboxItem.license(name: "Parallels")
        try store.upsert(item)
        keychain.set(
            "XXXX-YYYY", service: KeychainStore.service, account: KeychainStore.account(for: item.id))
        XCTAssertNotNil(
            keychain.get(
                service: KeychainStore.service, account: KeychainStore.account(for: item.id)))

        // 删除条目:必须先清 Keychain 再改清单(防泄漏残留)
        try store.deleteItem(item.id)
        XCTAssertNil(
            keychain.get(
                service: KeychainStore.service, account: KeychainStore.account(for: item.id)))
        XCTAssertNil(store.item(withID: item.id))
    }

    /// 删除非激活码条目也不残留任何 Keychain 项
    func testStoreDeleteNonLicenseClearsKeychainToo() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let keychain = InMemoryKeychain()
        let store = ToolboxStore(directory: dir, keychain: keychain)
        let item = ToolboxItem.toolLink(name: "Raycast", url: "https://raycast.com")
        try store.upsert(item)
        try store.deleteItem(item.id)
        XCTAssertNil(
            keychain.get(
                service: KeychainStore.service, account: KeychainStore.account(for: item.id)))
    }

    // MARK: - 快照目录清理联动

    func testStoreDeleteRemovesSnapshotDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ToolboxStore(directory: dir, keychain: InMemoryKeychain())
        let item = ToolboxItem.configSnapshot(
            name: ".zshrc", sourcePath: "~/.zshrc",
            meta: SnapshotMeta(
                fileNameOnDisk: ".zshrc", sha256: "x", byteSize: 1, capturedAt: Date(),
                sourceMtime: nil))
        try store.upsert(item)
        try store.writeSnapshotData(Data("hello".utf8), itemID: item.id, fileNameOnDisk: ".zshrc")
        XCTAssertTrue(store.snapshotFileExists(for: item))

        try store.deleteItem(item.id)
        XCTAssertFalse(store.snapshotFileExists(for: item))
    }

    /// 孤儿清扫:不在清单中的快照目录被删除
    func testOrphanSweepRemovesUnknownDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchx-keychain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ToolboxStore(directory: dir, keychain: InMemoryKeychain())
        let item = ToolboxItem.toolLink(name: "x", url: "https://x.com")
        try store.upsert(item)

        // 造一个孤儿目录
        let orphan = store.snapshotsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        store.performOrphanSweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
