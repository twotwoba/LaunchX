import XCTest
@testable import LaunchX

/// SearchEngine 纯函数的单元测试（不实例化单例，只测静态方法）。
final class SearchEngineTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - prefixCompress（rm -rf 逐文件事件压缩成子树删除）

    func testPrefixCompressAbsorbsDescendants() {
        let input = [
            "/a/b/c/d.txt",
            "/a/b",           // 吸收上面的子文件
            "/x/y.txt",
            "/a/b2/e.txt",    // "/a/b" 的兄弟（前缀相近但非子路径），必须保留
        ]
        // 注意：压缩只吸收「已选根的后代」，不会把 /a/b2/e.txt 缩短成 /a/b2
        let result = SearchEngine.prefixCompress(input)
        XCTAssertEqual(result, ["/a/b", "/a/b2/e.txt", "/x/y.txt"])
    }

    func testPrefixCompressSortsAndDedupes() {
        let result = SearchEngine.prefixCompress([
            "/x",
            "/x",
            "/a/b",
            "/a",
        ])
        XCTAssertEqual(result, ["/a", "/x"])
    }

    func testPrefixCompressEmptyInput() {
        XCTAssertEqual(SearchEngine.prefixCompress([]), [])
    }

    // MARK: - isPackageBundle（目录 created 事件是否展开子树）

    func testIsPackageBundle() {
        XCTAssertTrue(SearchEngine.isPackageBundle(path: "/Applications/Xcode.app"))
        XCTAssertTrue(SearchEngine.isPackageBundle(path: "/tmp/installer.pkg"))
        XCTAssertTrue(SearchEngine.isPackageBundle(path: "/tmp/Something.framework"))

        // 普通文件与普通目录
        XCTAssertFalse(SearchEngine.isPackageBundle(path: "/tmp/notes.txt"))
        XCTAssertFalse(SearchEngine.isPackageBundle(path: "/tmp/Projects"))

        // app 内部文件：最后一段不是 bundle，但补扫侧由 isInsidePackage 处理
        XCTAssertFalse(SearchEngine.isPackageBundle(path: "/Applications/Xcode.app/Contents/Info.plist"))
    }
}
