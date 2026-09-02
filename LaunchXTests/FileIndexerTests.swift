import XCTest
@testable import LaunchX

/// FileIndexer 记录构建 / 子树补扫的单元测试（基于临时目录）。
final class FileIndexerTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileIndexerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root = tempRoot {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    @discardableResult
    private func writeFile(_ relativePath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "test".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 构造一个带 Info.plist（含 CFBundleIconFile）的假 .app
    @discardableResult
    private func writeFakeApp(_ relativePath: String, iconFile: String? = "AppIcon") throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let iconFile = iconFile {
            let plist = ["CFBundleIconFile": iconFile]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
        return url
    }

    // MARK: - makeRecord

    func testMakeRecordKeepsExtension() throws {
        let url = try writeFile("hello.swift")
        let record = try XCTUnwrap(FileIndexer.makeRecord(for: url))
        XCTAssertEqual(record.name, "hello.swift")  // 名称保留扩展名
        XCTAssertEqual(record.extension, "swift")
        XCTAssertFalse(record.isDirectory)
    }

    func testMakeRecordDetectsDirectory() throws {
        let dir = tempRoot.appendingPathComponent("somedir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let record = try XCTUnwrap(FileIndexer.makeRecord(for: dir))
        XCTAssertTrue(record.isDirectory)
    }

    func testMakeRecordGeneratesPinyinForChineseName() throws {
        let url = try writeFile("微信.txt")
        let record = try XCTUnwrap(FileIndexer.makeRecord(for: url))
        // 中文转拼音、ASCII 部分（.txt）原样保留、去除空格
        XCTAssertEqual(record.pinyinFull, "weixin.txt")
        XCTAssertEqual(record.pinyinAcronym, "wx")
    }

    func testMakeRecordAppWithoutIconIsFiltered() throws {
        // 无 Info.plist 的 .app 视为辅助程序（如 WiFiAgent），不入索引
        let url = try writeFakeApp("NoIcon.app", iconFile: nil)
        XCTAssertNil(FileIndexer.makeRecord(for: url))
    }

    func testMakeRecordAppWithIconKept() throws {
        let url = try writeFakeApp("Fake.app")
        let record = try XCTUnwrap(FileIndexer.makeRecord(for: url))
        XCTAssertTrue(record.isApp)
    }

    func testMakeRecordFiltersElectronHelperApps() throws {
        // Electron/Chromium 辅助进程（名字含 " Helper"）即使有图标也不入索引
        let url = try writeFakeApp("Cursor Helper.app")
        XCTAssertNil(FileIndexer.makeRecord(for: url))
    }

    // MARK: - collectSubtreeRecords

    func testCollectSubtreeRecordsRespectsExclusions() throws {
        let root = tempRoot.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeFile("proj/a.swift")
        try writeFile("proj/node_modules/dep.js")
        try writeFile("proj/.hidden.txt")  // enumerator skipsHiddenFiles
        try writeFakeApp("proj/Inner.app")  // package 后代跳过
        try writeFile("proj/Inner.app/Contents/MacOS/binary")
        try writeFile("proj/build.log")

        let indexer = FileIndexer()
        let records = indexer.collectSubtreeRecords(
            root: root,
            excludedNames: ["node_modules"],
            excludedExtensions: ["log"]
        )
        let paths = Set(records.map { $0.path })

        // enumerator 遍历时会把 /var/... 解析成 /private/var/...，用后缀匹配避免前缀差异
        XCTAssertTrue(paths.contains(root.path), "应包含根目录本身: \(paths.sorted())")
        XCTAssertTrue(
            paths.contains { $0.hasSuffix("proj/a.swift") },
            "应包含 a.swift: \(paths.sorted())")
        XCTAssertFalse(paths.contains { $0.contains("dep.js") }, "排除目录的子文件不应被收集")
        XCTAssertFalse(paths.contains { $0.contains(".hidden") }, "隐藏文件不应被收集")
        XCTAssertFalse(paths.contains { $0.contains("binary") }, "package 内部文件不应被收集")
        XCTAssertFalse(paths.contains { $0.contains("build.log") }, "排除扩展名不应被收集")
    }

    func testCollectSubtreeRecordsRootExcludedReturnsEmpty() {
        let root = tempRoot.appendingPathComponent("node_modules")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let records = FileIndexer().collectSubtreeRecords(
            root: root, excludedNames: ["node_modules"])
        XCTAssertTrue(records.isEmpty, "根目录命中排除规则应整体返回空")
    }
}
