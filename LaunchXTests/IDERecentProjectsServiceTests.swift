import XCTest

@testable import LaunchX

final class IDERecentProjectsServiceTests: XCTestCase {
    // MARK: - Helpers

    /// 在临时目录创建真实存在的项目目录，返回 (绝对路径, XML 中的 key)。
    /// 使用 $USER_HOME$ 占位符以贴近真实 recentProjects.xml 结构。
    private func makeJetBrainsProjectDirs(prefix: String) throws -> [(path: String, key: String)] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var result: [(String, String)] = []
        for name in ["jb_proj_a", "jb_proj_b", "jb_proj_c"] {
            let abs = tmp.appendingPathComponent(name).path
            try FileManager.default.createDirectory(
                atPath: abs, withIntermediateDirectories: true)
            // key 使用 $USER_HOME$ 占位符，仅当目录位于 home 下时才能替换还原；
            // 这里目录在临时目录下，故直接使用绝对路径作为 key（解析器对无占位符的路径原样保留）。
            result.append((abs, abs))
            _ = home  // 保留以备将来切换到 home 下测试
        }
        return result
    }

    func testRunCommandCapturesLargeStdoutWithoutDeadlocking() throws {
        let completed = expectation(description: "command completes")
        var output: String?
        var thrownError: Error?

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                output = try IDERecentProjectsService.runCommand(
                    executablePath: "/usr/bin/python3",
                    arguments: [
                        "-c", "import sys; sys.stdout.write('a' * 100000)",
                    ])
            } catch {
                thrownError = error
            }

            completed.fulfill()
        }

        wait(for: [completed], timeout: 2.0)
        XCTAssertNil(thrownError)
        XCTAssertEqual(output?.count, 100_000)
    }

    /// JetBrains 的 recentProjects.xml 中 entry 顺序是"首次加入"的插入顺序，
    /// 而非最近打开顺序。解析器必须读取 activationTimestamp 并按其降序排序，
    /// 最近打开的项目才会出现在列表最前。
    func testJetBrainsRecentProjectsSortedByActivationTimestamp() throws {
        let dirs = try makeJetBrainsProjectDirs(prefix: "launchx_jb_test")
        let (aPath, aKey) = dirs[0]
        let (bPath, bKey) = dirs[1]
        let (cPath, cKey) = dirs[2]
        defer {
            for p in [aPath, bPath, cPath] { try? FileManager.default.removeItem(atPath: p) }
            try? FileManager.default.removeItem(
                atPath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("launchx_jb_test").path)
        }

        // 文档顺序为 A、B、C，但激活时间分别为最旧、最新、居中。
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo">
                  <map>
                    <entry key="\(aKey)">
                      <value>
                        <RecentProjectMetaInfo>
                          <option name="activationTimestamp" value="1000" />
                          <option name="projectOpenTimestamp" value="1000" />
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
                    <entry key="\(bKey)">
                      <value>
                        <RecentProjectMetaInfo>
                          <option name="activationTimestamp" value="3000" />
                          <option name="projectOpenTimestamp" value="500" />
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
                    <entry key="\(cKey)">
                      <value>
                        <RecentProjectMetaInfo>
                          <option name="activationTimestamp" value="2000" />
                          <option name="projectOpenTimestamp" value="2000" />
                        </RecentProjectMetaInfo>
                      </value>
                    </entry>
                  </map>
                </option>
                <option name="lastOpenedProject" value="\(bKey)" />
              </component>
            </application>
            """

        let projects = IDERecentProjectsService.parseJetBrainsRecentProjectsXML(
            xml, ideType: .jetbrainsIntelliJ, limit: 20)

        // 期望顺序：B(3000) -> C(2000) -> A(1000)，与文档顺序相反
        XCTAssertEqual(projects.map(\.name), ["jb_proj_b", "jb_proj_c", "jb_proj_a"])
        XCTAssertEqual(
            projects.first?.lastOpened, Date(timeIntervalSince1970: 3),
            "最近打开的项目应在最前，且 lastOpened 应来自 activationTimestamp")
        XCTAssertNotNil(projects.first?.lastOpened)
    }

    /// limit 在排序后生效：即便最新的项目在 XML 中靠后，也应被保留在结果中。
    func testJetBrainsRecentProjectsLimitAppliedAfterSort() throws {
        let dirs = try makeJetBrainsProjectDirs(prefix: "launchx_jb_limit_test")
        let (aPath, aKey) = dirs[0]
        let (bPath, bKey) = dirs[1]
        let (cPath, cKey) = dirs[2]
        defer {
            for p in [aPath, bPath, cPath] { try? FileManager.default.removeItem(atPath: p) }
            try? FileManager.default.removeItem(
                atPath: FileManager.default.temporaryDirectory
                    .appendingPathComponent("launchx_jb_limit_test").path)
        }

        let xml = """
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo">
                  <map>
                    <entry key="\(aKey)"><value><RecentProjectMetaInfo>
                      <option name="activationTimestamp" value="1000" />
                    </RecentProjectMetaInfo></value></entry>
                    <entry key="\(bKey)"><value><RecentProjectMetaInfo>
                      <option name="activationTimestamp" value="3000" />
                    </RecentProjectMetaInfo></value></entry>
                    <entry key="\(cKey)"><value><RecentProjectMetaInfo>
                      <option name="activationTimestamp" value="2000" />
                    </RecentProjectMetaInfo></value></entry>
                  </map>
                </option>
              </component>
            </application>
            """

        // limit=2：应保留最新的两个 B、C，丢掉最旧的 A
        let projects = IDERecentProjectsService.parseJetBrainsRecentProjectsXML(
            xml, ideType: .jetbrainsIntelliJ, limit: 2)
        XCTAssertEqual(projects.map(\.name), ["jb_proj_b", "jb_proj_c"])
    }

    // MARK: - JetBrains workspace 合并（IDEA 2024+ 的"实时"最近项目）

    /// 在临时目录搭建一个迷你 JetBrains 配置布局（options/recentProjects.xml + workspace/*.xml）。
    /// projectNames 中的每个名字都会创建一个真实存在的项目根目录（保证 fileExists 过滤通过）。
    private func makeJetBrainsConfigLayout(prefix: String, projectNames: [String]) throws
        -> (recentProjectsPath: String, workspaceDir: String, roots: [String: String])
    {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try? FileManager.default.removeItem(at: tmp)
        let configDir = tmp.appendingPathComponent("IntelliJIdea2099.1")
        let optionsDir = configDir.appendingPathComponent("options")
        let workspaceDir = configDir.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: optionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        var roots: [String: String] = [:]
        for name in projectNames {
            let abs = tmp.appendingPathComponent("roots").appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: abs, withIntermediateDirectories: true)
            roots[name] = abs
        }
        return (optionsDir.appendingPathComponent("recentProjects.xml").path, workspaceDir.path, roots)
    }

    private func writeAtomic(_ content: String, to path: String) throws {
        try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// workspace XML 里同时出现项目根与更深的子目录 file:// 引用，应取最浅（最短）的根；
    /// 仅含 `$PROJECT_DIR$` 宏的引用应被忽略。
    func testExtractJetBrainsWorkspacePathPicksShallowestRoot() throws {
        let prefix = "launchx_jb_wspath"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(atPath: tmp.path) }

        let root = tmp.appendingPathComponent("projA").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        let xml = """
            <project version="4">
              <component name="ProjectView">
                <item name="dir{file://\(root)/server/src/main/resources}" />
                <item name="dir{file://\(root)}" />
                <entry file="file://$PROJECT_DIR$/api/Foo.java" />
              </component>
            </project>
            """
        let file = tmp.appendingPathComponent("WSA.xml").path
        try writeAtomic(xml, to: file)

        XCTAssertEqual(IDERecentProjectsService.extractJetBrainsWorkspacePath(at: file), root)
    }

    /// recentProjects.xml（可能滞后）+ workspace/ 合并：
    /// - 仅出现在 workspace 的新项目 C 应被补出；
    /// - A 的时间应被 workspace 较新的修改时间覆盖（activationTimestamp 滞后）；
    /// - B 没有 workspace 文件，沿用 recentProjects 的时间。
    func testJetBrainsMergedAddsWorkspaceProjectsAndRefreshesTimestamp() throws {
        let prefix = "launchx_jb_merge"
        let topTmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix).path
        defer { try? FileManager.default.removeItem(atPath: topTmp) }

        let (recentPath, workspaceDir, roots) = try makeJetBrainsConfigLayout(
            prefix: prefix, projectNames: ["projA", "projB", "projC"])
        let absA = roots["projA"]!, absB = roots["projB"]!, absC = roots["projC"]!

        // recentProjects：含 A、B，不含 C（模拟尚未落盘的新项目）
        let recentXML = """
            <application>
              <component name="RecentProjectsManager">
                <option name="additionalInfo"><map>
                  <entry key="\(absA)"><value><RecentProjectMetaInfo projectWorkspaceId="WSA">
                    <option name="activationTimestamp" value="1000" />
                  </RecentProjectMetaInfo></value></entry>
                  <entry key="\(absB)"><value><RecentProjectMetaInfo projectWorkspaceId="WSB">
                    <option name="activationTimestamp" value="2000" />
                  </RecentProjectMetaInfo></value></entry>
                </map></option>
              </component>
            </application>
            """
        try writeAtomic(recentXML, to: recentPath)

        // workspace：A（时间更新）+ C（recentProjects 里没有的新项目）
        let wsA = """
            <project version="4"><component name="ProjectView">
              <item name="dir{file://\(absA)}" />
            </component></project>
            """
        let wsAPath = (workspaceDir as NSString).appendingPathComponent("WSA.xml")
        try writeAtomic(wsA, to: wsAPath)

        let wsC = """
            <project version="4"><component name="ProjectView">
              <item name="dir{file://\(absC)}" />
            </component></project>
            """
        let wsCPath = (workspaceDir as NSString).appendingPathComponent("WSC.xml")
        try writeAtomic(wsC, to: wsCPath)

        // 显式设定 workspace 文件修改时间，保证排序确定（C 最新 > A > B≈1970）
        let tA = Date(timeIntervalSince1970: 2_000_000_000)
        let tC = Date(timeIntervalSince1970: 2_100_000_000)
        try FileManager.default.setAttributes([.modificationDate: tA], ofItemAtPath: wsAPath)
        try FileManager.default.setAttributes([.modificationDate: tC], ofItemAtPath: wsCPath)

        let projects = IDERecentProjectsService.shared.parseJetBrainsRecentProjectsMerged(
            recentProjectsPath: recentPath, workspaceDir: workspaceDir,
            ideType: .jetbrainsIntelliJ, limit: 20)

        XCTAssertEqual(projects.map(\.name), ["projC", "projA", "projB"])
        // A 的 lastOpened 应来自 workspace 的较新时间，而非滞后的 activationTimestamp(1000ms≈1970)
        if let a = projects.first(where: { $0.name == "projA" }), let opened = a.lastOpened {
            XCTAssertLessThan(abs(opened.timeIntervalSince(tA)), 1, "A 应采用 workspace 更新的时间")
        } else {
            XCTFail("projA 缺失或无 lastOpened")
        }
    }

    /// workspace 文件内仅含 `$PROJECT_DIR$` 宏（无绝对路径）时，应通过文件名（workspaceId）
    /// 在 recentProjects.xml 中反查路径。
    func testJetBrainsMergedResolvesProjectDirMacroViaWorkspaceId() throws {
        let prefix = "launchx_jb_macro"
        let topTmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix).path
        defer { try? FileManager.default.removeItem(atPath: topTmp) }

        let (recentPath, workspaceDir, roots) = try makeJetBrainsConfigLayout(
            prefix: prefix, projectNames: ["projD"])
        let absD = roots["projD"]!

        let recentXML = """
            <application><component name="RecentProjectsManager">
              <option name="additionalInfo"><map>
                <entry key="\(absD)"><value><RecentProjectMetaInfo projectWorkspaceId="WSD">
                  <option name="activationTimestamp" value="1000" />
                </RecentProjectMetaInfo></value></entry>
              </map></option>
            </component></application>
            """
        try writeAtomic(recentXML, to: recentPath)

        // 仅含 $PROJECT_DIR$，无 file:///<绝对路径>
        let wsD = """
            <project version="4"><component name="FileEditorManager">
              <entry file="file://$PROJECT_DIR$/src/main/Foo.java" />
            </component></project>
            """
        let wsDPath = (workspaceDir as NSString).appendingPathComponent("WSD.xml")
        try writeAtomic(wsD, to: wsDPath)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)], ofItemAtPath: wsDPath)

        let projects = IDERecentProjectsService.shared.parseJetBrainsRecentProjectsMerged(
            recentProjectsPath: recentPath, workspaceDir: workspaceDir,
            ideType: .jetbrainsIntelliJ, limit: 20)

        XCTAssertEqual(projects.map(\.name), ["projD"])
        XCTAssertNotNil(projects.first?.lastOpened)
    }

    // MARK: - Winc

    /// 在临时目录创建真实存在的项目目录，返回按名字索引的绝对路径。
    private func makeWincProjectDirs(prefix: String, names: [String]) throws -> [String: String] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(prefix)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        var result: [String: String] = [:]
        for name in names {
            let abs = tmp.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: abs, withIntermediateDirectories: true)
            result[name] = abs
        }
        return result
    }

    /// Winc 的 `recent` 顺序即最近打开顺序（最新的在前），解析应保持原序、去重并过滤不存在的路径。
    func testWincRecentProjectsKeepsOrderAndDeduplicates() throws {
        let roots = try makeWincProjectDirs(
            prefix: "launchx_winc_parse", names: ["projA", "projB", "projC"])
        let a = roots["projA"]!, b = roots["projB"]!, c = roots["projC"]!

        // 缺失路径应被过滤；重复路径应去重（保留首次出现位置）
        let paths = [a, b, "/nonexistent/winc/project", c, a]
        let projects = IDERecentProjectsService.shared.parseWincRecentProjects(paths, limit: 20)

        XCTAssertEqual(projects.map(\.name), ["projA", "projB", "projC"])
        XCTAssertEqual(projects.map(\.path), [a, b, c])
        XCTAssertTrue(projects.allSatisfy { $0.ideType == .winc })
    }

    /// limit 应在去重/过滤之前生效——只取数组前 limit 个有效条目。
    func testWincRecentProjectsLimitApplied() throws {
        let roots = try makeWincProjectDirs(
            prefix: "launchx_winc_limit", names: ["projA", "projB", "projC"])
        let a = roots["projA"]!, b = roots["projB"]!, c = roots["projC"]!

        let projects = IDERecentProjectsService.shared.parseWincRecentProjects(
            [a, b, c], limit: 2)

        XCTAssertEqual(projects.map(\.name), ["projA", "projB"])
    }
}
