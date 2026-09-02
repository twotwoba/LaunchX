import XCTest
@testable import LaunchX

/// MemoryIndex 检索/增删的单元测试。
/// 覆盖：有序数组二分前缀检索、bigram 倒排 contains 全量召回、懒删除、
/// 紧凑重建、拼音检索、单字符回退、maxResults、去重与排序语义。
/// MemoryIndex 内部用串行 DispatchQueue，公开 API 异步执行，测试需用 drainQueue 等待。
final class MemoryIndexTests: XCTestCase {

    private func makeRecord(
        path: String,
        name: String? = nil,
        isDirectory: Bool = false,
        pinyinFull: String? = nil,
        pinyinAcronym: String? = nil,
        modifiedDate: Date = Date()
    ) -> FileRecord {
        return FileRecord(
            name: name ?? (path as NSString).lastPathComponent,
            path: path,
            extension: (path as NSString).pathExtension.lowercased(),
            isApp: false,
            isDirectory: isDirectory,
            pinyinFull: pinyinFull,
            pinyinAcronym: pinyinAcronym,
            modifiedDate: modifiedDate
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

    // MARK: - 前缀检索（有序数组 + 二分）

    func testPrefixSearchFindsRangeMatches() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/abc.txt"),
            makeRecord(path: "/tmp/abd.txt"),
            makeRecord(path: "/tmp/acd.txt"),
        ])

        drainQueue(index) {
            let paths = Set(index.search(query: "ab").map { $0.path })
            XCTAssertEqual(paths, ["/tmp/abc.txt", "/tmp/abd.txt"])
            XCTAssertEqual(index.search(query: "zzz").count, 0)
        }
    }

    func testPrefixSearchAfterAddBatch() {
        let index = MemoryIndex()
        index.build(from: [makeRecord(path: "/tmp/ab1.txt")])

        drainQueue(index) {
            index.addBatch([self.makeRecord(path: "/tmp/ab2.txt")])

            self.drainQueue(index) {
                // 归并插入后二分检索仍能同时命中新旧条目
                let paths = Set(index.search(query: "ab").map { $0.path })
                XCTAssertEqual(paths, ["/tmp/ab1.txt", "/tmp/ab2.txt"])
            }
        }
    }

    func testChinesePrefixSearch() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/微信", name: "微信", isDirectory: true),
            makeRecord(path: "/tmp/微博", name: "微博", isDirectory: true),
        ])

        drainQueue(index) {
            let paths = index.search(query: "微").map { $0.path }
            XCTAssertEqual(paths.count, 2)
            XCTAssertEqual(index.search(query: "信").first?.path, "/tmp/微信")
        }
    }

    // MARK: - bigram 倒排（contains 全量召回）

    func testBigramContainsFindsMiddleMatch() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/my_report_final.txt"),
            makeRecord(path: "/tmp/notes.txt"),
        ])

        drainQueue(index) {
            // "report" 是中缀：前缀检索覆盖不到，靠 bigram 倒排召回
            XCTAssertEqual(index.search(query: "report").first?.path, "/tmp/my_report_final.txt")
        }
    }

    func testBigramRecallsOldFileBeyondLinearScanLimit() {
        let index = MemoryIndex()
        // 250 个较新的干扰文件（名字不含 report 的任何 bigram 字符对）
        var records = (0..<250).map { i in
            makeRecord(
                path: "/tmp/data/file_\(i)_data.txt",
                modifiedDate: Date(timeIntervalSinceNow: -Double(i))
            )
        }
        // 目标：最老的文件（线性扫描 files.prefix(200) 永远扫不到它）
        records.append(makeRecord(
            path: "/tmp/data/zz_report.txt",
            modifiedDate: Date(timeIntervalSinceNow: -100_000)
        ))
        index.build(from: records)

        drainQueue(index) {
            let results = index.search(query: "report")
            XCTAssertEqual(results.map { $0.path }, ["/tmp/data/zz_report.txt"])
        }
    }

    func testBigramRejectsCrossingBigrams() {
        let index = MemoryIndex()
        index.build(from: [makeRecord(path: "/tmp/report.txt")])

        drainQueue(index) {
            // "rp" 不是 "report" 中的相邻字符对，不应命中
            XCTAssertEqual(index.search(query: "rp").count, 0)
            // "oreport" 的每个 bigram（or/re/ep/po/rt）都存在，但整体不是子串，也不应命中
            XCTAssertEqual(index.search(query: "oreport").count, 0)
        }
    }

    func testBigramContainsNoDuplicateWithPrefixMatch() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/report.txt"),
            makeRecord(path: "/tmp/my_report.txt"),
        ])

        drainQueue(index) {
            let paths = index.search(query: "report").map { $0.path }
            // 前缀命中（report.txt）与中缀命中（my_report.txt）各出现一次，不重复
            XCTAssertEqual(paths.count, 2)
            XCTAssertEqual(Set(paths).count, 2)
        }
    }

    // MARK: - removeSubtree 级联删除 / 懒删除

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

    func testRemovedItemHiddenFromContainsSearch() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/a/my_report.txt"),
            makeRecord(path: "/tmp/b/other.txt"),
        ])

        drainQueue(index) {
            index.removeSubtree(atPath: "/tmp/a")

            self.drainQueue(index) {
                // 懒删除：posting 里残留的条目被身份校验过滤
                XCTAssertEqual(index.search(query: "report").count, 0)
                XCTAssertEqual(index.search(query: "other").count, 1)
            }
        }
    }

    func testReAddPathReplacesStaleEntry() {
        let index = MemoryIndex()
        index.build(from: [makeRecord(path: "/tmp/x/report.txt")])

        drainQueue(index) {
            index.removeBatch(paths: ["/tmp/x/report.txt"])
            self.drainQueue(index) {
                index.addBatch([self.makeRecord(path: "/tmp/x/report.txt")])

                self.drainQueue(index) {
                    // 同路径重新加入后：陈旧对象被过滤，新对象恰好命中一次
                    XCTAssertEqual(index.search(query: "report").count, 1)
                    XCTAssertEqual(index.totalCount, 1)
                }
            }
        }
    }

    func testRemoveSubtreeCleansPrefixCandidates() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/proj/alpha.txt"),
            makeRecord(path: "/tmp/other/beta.txt"),
        ])

        drainQueue(index) {
            XCTAssertEqual(index.search(query: "alpha").count, 1)

            index.removeSubtree(atPath: "/tmp/proj")

            self.drainQueue(index) {
                // 前缀候选也必须清理干净（懒删除对前缀检索同样生效）
                XCTAssertEqual(index.search(query: "alpha").count, 0)
                XCTAssertEqual(index.search(query: "beta").count, 1)
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

    // MARK: - 紧凑重建

    func testRebuildIndexesKeepsSearchesCorrect() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/keep/alpha_report.txt"),
            makeRecord(path: "/tmp/drop/beta_report.txt"),
            makeRecord(path: "/tmp/keep/gamma.txt"),
        ])

        drainQueue(index) {
            index.removeSubtree(atPath: "/tmp/drop")
            index.rebuildIndexes()

            self.drainQueue(index) {
                XCTAssertEqual(index.totalCount, 2)
                let reports = Set(index.search(query: "report").map { $0.path })
                XCTAssertEqual(reports, ["/tmp/keep/alpha_report.txt"])
                XCTAssertEqual(index.search(query: "gamma").count, 1)
                XCTAssertEqual(index.search(query: "beta").count, 0)
            }
        }
    }

    // MARK: - 拼音检索

    func testPinyinAcronymAndFullPrefixSearch() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(
                path: "/tmp/微信",
                name: "微信",
                isDirectory: true,
                pinyinFull: "weixin",
                pinyinAcronym: "wx"
            ),
        ])

        drainQueue(index) {
            // 拼音缩写前缀
            XCTAssertEqual(index.search(query: "wx").first?.path, "/tmp/微信")
            // 全拼前缀
            XCTAssertEqual(index.search(query: "wei").first?.path, "/tmp/微信")
        }
    }

    // MARK: - 单字符查询回退

    func testSingleCharQueryFallsBackToLinearScan() {
        let index = MemoryIndex()
        index.build(from: [makeRecord(path: "/tmp/notes.txt")])

        drainQueue(index) {
            // 单字符无 bigram，走最近文件线性扫描回退（"o" 是中缀）
            XCTAssertEqual(index.search(query: "o").first?.path, "/tmp/notes.txt")
        }
    }

    // MARK: - 结果上限 / 排序语义

    func testMaxResultsRespected() {
        let index = MemoryIndex()
        let records = (1...40).map { i in
            makeRecord(path: "/tmp/ab_\(i).txt", modifiedDate: Date(timeIntervalSinceNow: -Double(i)))
        }
        index.build(from: records)

        drainQueue(index) {
            XCTAssertEqual(index.search(query: "ab", maxResults: 5).count, 5)
        }
    }

    func testExactMatchRanksBeforePrefixAndContains() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/my_ab.txt", modifiedDate: Date(timeIntervalSinceNow: -1)),
            makeRecord(path: "/tmp/ab", modifiedDate: Date(timeIntervalSinceNow: -2)),
            makeRecord(path: "/tmp/abc.txt", modifiedDate: Date(timeIntervalSinceNow: -3)),
        ])

        drainQueue(index) {
            let paths = index.search(query: "ab").map { $0.path }
            XCTAssertEqual(paths.first, "/tmp/ab")  // 精确匹配 > 前缀 > 中缀
            XCTAssertEqual(Set(paths).count, paths.count)  // 无重复
        }
    }

    func testDirectoryRanksBeforeFileAtSameMatchType() {
        let index = MemoryIndex()
        index.build(from: [
            makeRecord(path: "/tmp/proj_notes.txt", modifiedDate: Date(timeIntervalSinceNow: -1)),
            makeRecord(path: "/tmp/proj_src", name: "proj_src", isDirectory: true, modifiedDate: Date(timeIntervalSinceNow: -2)),
        ])

        drainQueue(index) {
            let paths = index.search(query: "proj").map { $0.path }
            XCTAssertEqual(paths.first, "/tmp/proj_src")  // 同为前缀命中，目录优先于文件
        }
    }

    // MARK: - 别名

    func testAliasExactMatchTakesPriority() {
        let index = MemoryIndex()
        index.setAliasMap(["wxapp": "/tmp/wechat.app"])
        index.build(from: [
            makeRecord(path: "/tmp/wechat.app", name: "WeChat"),
        ])

        drainQueue(index) {
            XCTAssertEqual(index.search(query: "wxapp").first?.path, "/tmp/wechat.app")
        }
    }
}
