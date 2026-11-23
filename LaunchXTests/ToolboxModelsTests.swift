import XCTest

@testable import LaunchX

/// 百宝箱模型:Codable 往返、身份键、合并语义(纯内存,不触盘)
final class ToolboxModelsTests: XCTestCase {

    // MARK: - Codable 往返

    func testCodableRoundTripAllKinds() throws {
        let items = [
            ToolboxItem.toolLink(name: "Raycast", url: "https://raycast.com", notes: "启动器"),
            ToolboxItem.brewPackage(name: "wget", kind: .formula),
            ToolboxItem.brewPackage(name: "google-chrome", kind: .cask, tap: "user/repo"),
            ToolboxItem.configSnapshot(
                name: ".zshrc",
                sourcePath: "~/.zshrc",
                meta: SnapshotMeta(
                    fileNameOnDisk: ".zshrc", sha256: "abc", byteSize: 12,
                    capturedAt: Date(timeIntervalSince1970: 1000), sourceMtime: nil)),
            ToolboxItem.license(name: "Parallels", account: "a@b.com"),
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(items)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([ToolboxItem].self, from: data)

        XCTAssertEqual(decoded.count, items.count)
        // 除自动生成的时间戳外逐字段一致
        for (original, roundTripped) in zip(items, decoded) {
            XCTAssertEqual(original.kind, roundTripped.kind)
            XCTAssertEqual(original.name, roundTripped.name)
            XCTAssertEqual(original.urlString, roundTripped.urlString)
            XCTAssertEqual(original.brewKind, roundTripped.brewKind)
            XCTAssertEqual(original.brewTap, roundTripped.brewTap)
            XCTAssertEqual(original.sourcePath, roundTripped.sourcePath)
            XCTAssertEqual(original.snapshotMeta, roundTripped.snapshotMeta)
            XCTAssertEqual(original.account, roundTripped.account)
        }
    }

    /// 容错解码:items 里混入坏条目时跳过坏条目,保留好条目
    func testTolerantDecodeSkipsUnknownItems() throws {
        let good = ToolboxItem.toolLink(name: "OK", url: "https://ok.com")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var container = try JSONSerialization.jsonObject(
            with: try encoder.encode(ToolboxManifest(items: [good]))) as! [String: Any]
        var rawItems = container["items"] as! [[String: Any]]
        rawItems.append(["kind": "futureKind", "name": "unknown-entry"])  // 无法识别的类型
        container["items"] = rawItems
        let data = try JSONSerialization.data(withJSONObject: container)

        let manifest = ToolboxManifest.tolerantDecode(from: data)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.items.count, 1)
        XCTAssertEqual(manifest?.items.first?.name, "OK")
    }

    // MARK: - 身份键(机器无关)

    func testLinkIdentityKeyNormalizesURL() {
        let a = ToolboxItem.toolLink(name: "A", url: "https://EXAMPLE.com/")
        let b = ToolboxItem.toolLink(name: "B", url: "https://example.com")
        XCTAssertEqual(a.sourceIdentityKey, b.sourceIdentityKey)
    }

    func testLinkIdentityKeyToleratesMissingScheme() {
        let a = ToolboxItem.toolLink(name: "A", url: "raycast.com")
        let b = ToolboxItem.toolLink(name: "B", url: "https://raycast.com")
        XCTAssertNotNil(a.sourceIdentityKey)
        XCTAssertEqual(a.sourceIdentityKey, b.sourceIdentityKey)
    }

    func testBrewIdentityKeyUsesKindAndName() {
        let formula = ToolboxItem.brewPackage(name: "wget", kind: .formula)
        let cask = ToolboxItem.brewPackage(name: "wget", kind: .cask)
        XCTAssertNotEqual(formula.sourceIdentityKey, cask.sourceIdentityKey)
        XCTAssertEqual(
            formula.sourceIdentityKey,
            ToolboxItem.brewPackage(name: "WGET", kind: .formula).sourceIdentityKey)
    }

    func testSnapshotIdentityKeyUsesSourcePath() {
        let a = ToolboxItem.configSnapshot(
            name: "zsh", sourcePath: "~/.zshrc",
            meta: SnapshotMeta(
                fileNameOnDisk: ".zshrc", sha256: "x", byteSize: 1, capturedAt: Date(),
                sourceMtime: nil))
        let b = ToolboxItem.configSnapshot(
            name: "my shell", sourcePath: "~/.zshrc",
            meta: SnapshotMeta(
                fileNameOnDisk: ".zshrc", sha256: "y", byteSize: 2, capturedAt: Date(),
                sourceMtime: nil))
        XCTAssertEqual(a.sourceIdentityKey, b.sourceIdentityKey)
    }

    func testLicenseIdentityKeyCaseInsensitiveName() {
        let a = ToolboxItem.license(name: "Parallels")
        let b = ToolboxItem.license(name: "parallels")
        XCTAssertEqual(a.sourceIdentityKey, b.sourceIdentityKey)
    }

    // MARK: - 合并语义

    func testMergeAddsNewItems() {
        var current = [ToolboxItem.brewPackage(name: "wget", kind: .formula)]
        let incoming = [
            ToolboxItem.brewPackage(name: "jq", kind: .formula),
            ToolboxItem.license(name: "Sketch"),
        ]
        let report = ToolboxTransferService.merge(
            into: &current, incoming: incoming, policy: .skipExisting)

        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(current.count, 3)
    }

    func testMergeIdenticalIsSilentlySkipped() {
        let existing = ToolboxItem.brewPackage(name: "wget", kind: .formula)
        var current = [existing]
        let sameContent = ToolboxItem.brewPackage(name: "wget", kind: .formula)
        let report = ToolboxTransferService.merge(
            into: &current, incoming: [sameContent], policy: .overwriteExisting)

        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.skipped, 0)  // 内容一致:静默,不计 skipped
        XCTAssertEqual(current.count, 1)
    }

    func testMergeSkipExistingKeepsCurrent() {
        var current = [ToolboxItem.toolLink(name: "旧名", url: "https://raycast.com")]
        let incoming = [ToolboxItem.toolLink(name: "新名", url: "https://raycast.com")]
        let report = ToolboxTransferService.merge(
            into: &current, incoming: incoming, policy: .skipExisting)

        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(current[0].name, "旧名")
    }

    /// 覆盖策略:内容更新为本机版本,但保留本机 id(Keychain/快照目录对应关系不丢)
    func testMergeOverwriteKeepsLocalIdentity() {
        var current = [ToolboxItem.license(name: "Parallels", account: "old@b.com")]
        let localID = current[0].id
        let incoming = [ToolboxItem.license(name: "Parallels", account: "new@b.com")]
        let incomingID = incoming[0].id

        let report = ToolboxTransferService.merge(
            into: &current, incoming: incoming, policy: .overwriteExisting)

        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(current[0].id, localID, "覆盖时应保留本机条目 id")
        XCTAssertEqual(current[0].account, "new@b.com", "内容应更新为导入版本")
        XCTAssertEqual(report.idMap[incomingID], localID)
    }

    func testBrewCommandString() {
        XCTAssertEqual(
            ToolboxItem.brewPackage(name: "wget", kind: .formula).brewCommand,
            "brew install wget")
        XCTAssertEqual(
            ToolboxItem.brewPackage(name: "chrome", kind: .cask, tap: "user/repo").brewCommand,
            "brew install --cask user/repo/chrome")
    }

    /// 文件名 sanitize:路径分隔符/控制字符被替换,取最后一级
    func testSanitizedFileName() {
        XCTAssertEqual(ToolboxStore.sanitizedFileName(from: "/Users/a/.zshrc"), ".zshrc")
        XCTAssertEqual(ToolboxStore.sanitizedFileName(from: "a/b:cd"), "b_cd")
        XCTAssertEqual(ToolboxStore.sanitizedFileName(from: ""), "snapshot")
        XCTAssertEqual(ToolboxStore.sanitizedFileName(from: ".."), "snapshot")
    }
}
