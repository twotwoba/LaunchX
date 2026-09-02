import XCTest
@testable import LaunchX

/// MemoryIndex 级联删除 / 批量增删的单元测试。
/// MemoryIndex 内部用串行 DispatchQueue，公开 API 异步执行，测试需用 expectation 等待。
final class MemoryIndexTests: XCTestCase {

    private func makeRecord(path: String, name: String? = nil, isDirectory: Bool = false) -> FileRecord {
        return FileRecord(
            name: name ?? (path as NSString).lastPathComponent,
            path: path,
            extension: (path as NSString).pathExtension.lowercased(),
            isApp: false,
            isDirectory: isDirectory,
            modifiedDate: Date()
        )
    }

    /// 等待 MemoryIndex 串行队列排空（所有异步操作完成）
    private func drainQueue(_ index: MemoryIndex, _ completion: @escaping () -> Void) {
        let expectation = expectation(description: "drain")
        index.removeBatch(paths: ["/__nonexistent_drain__"]) { expectation.fulfill() }
        waitForExpectations(timeout: 5)
        completion()
    }

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - removeSubtree 级联删除

    func testRemoveSubtreeCascadesChildren() {
        let index = MemoryIndex()
        let records = [
            makeRecord(path: "/tmp/proj"),
            makeRecord(path: "/tmp/proj/a.swift"),
            makeRecord(path: "/tmp/proj/sub/b.swift"),
            makeRecord(path: "/tmp/proj-other/c.swift"),  // 同级前缀，不应被删
            makeRecord(path: "/tmp/proj2/d.swift"),  // 同级前缀，不应被删
        ]
        index.build(from: records)

        drainQueue(index) {
            XCTAssertEqual(index.search(query: "swift").count, 4)

            index.removeSubtree(atPath: "/tmp/proj")

            self.drainQueue(index) {
                let results = index.search(query: "swift")
                XCTAssertEqual(Set(results.map { $0.path }), ["/tmp/proj-other/c.swift", "/tmp/proj2/d.swift"])
                XCTAssertEqual(index.totalCount, 2)
            }
        }
    }

    func testRemoveSubtreeForFileDoesNotHurtSiblings() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/report.pdf"),
            makeRecord(path: "/tmp/report-v2.pdf"),
        ])

        drainQueue(index) {
            index.removeSubtree(atPath: "/tmp/report.pdf")

            self.drainQueue(index) {
                // 删除文件本身，不误伤前缀相近的兄弟文件
                XCTAssertEqual(index.totalCount, 1)
                XCTAssertEqual(index.search(query: "report").first?.path, "/tmp/report-v2.pdf")
            }
        }
    }

    // MARK: - addBatch

    func testAddBatchSkipsExistingAndMergesFiles() {
        let index = MemoryIndex()
        index.build(from: [makeRecord(path: "/tmp/old.swift")])

        drainQueue(index) {
            index.addBatch([
                self.makeRecord(path: "/tmp/old.swift"),  // 已存在，跳过
                self.makeRecord(path: "/tmp/new.swift"),
            ])

            self.drainQueue(index) {
                XCTAssertEqual(index.totalCount, 2)
                XCTAssertEqual(index.search(query: "swift").count, 2)
            }
        }
    }

    // MARK: - Trie 一致性（删除后前缀搜索不残留）

    func testRemoveSubtreeCleansTrie() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/proj/alpha.txt"),
            makeRecord(path: "/tmp/other/beta.txt"),
        ])

        drainQueue(index) {
            XCTAssertEqual(index.search(query: "alpha").count, 1)

            index.removeSubtree(atPath: "/tmp/proj")

            self.drainQueue(index) {
                // Trie 前缀候选也必须清理干净
                XCTAssertEqual(index.search(query: "alpha").count, 0)
                XCTAssertEqual(index.search(query: "beta").count, 1)
            }
        }
    }
}
