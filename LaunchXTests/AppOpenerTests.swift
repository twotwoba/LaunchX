import XCTest
@testable import LaunchX

/// AppOpener 派发契约测试 + 全局同步打开调用守卫。
///
/// 背景：`NSWorkspace.shared.open(_:)` 是【同步】调用，打开应用时会阻塞调用线程
/// 直到目标应用完成启动。冷启动重型应用期间主线程被卡住，快捷键/面板完全无法
/// 响应（用户表现为"启动一个 app 后无法再次唤起 LaunchX"）。
/// 因此：
/// 1. 所有打开操作必须走 AppOpener 的异步实现 + completionHandler 版系统 API；
/// 2. 由源码守卫测试禁止 AppOpener 之外出现同步打开调用，防止回归。
///
/// ⚠️ 本测试文件【严禁】真实调用 `AppOpener.open` 打开任何 URL：
/// 不存在的路径会弹 Finder「找不到该文件」对话框，存在的目标则会真的拉起应用。
/// 派发契约经 `dispatchToMain` 测试；打开语义经注入 stub（如 RemindersService.urlOpener）测试。
final class AppOpenerTests: XCTestCase {

    /// 线程安全的布尔标记（跨线程读写，避免数据竞争）
    private final class LockedFlag {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock()
            defer { lock.unlock() }
            value = true
        }
    }

    // MARK: - dispatchToMain 派发契约

    /// 主线程调用：同步执行 request 并返回 true（NSWorkspace 异步 API 自身立即返回，
    /// 不产生额外跳转开销；「不阻塞」由 completionHandler 版系统 API 保证）
    func testDispatchOnMainThreadExecutesSynchronouslyAndReturnsTrue() {
        let executed = LockedFlag()

        let returnValue = AppOpener.dispatchToMain {
            executed.set()
        }

        XCTAssertTrue(returnValue)
        XCTAssertTrue(executed.isSet, "主线程调用应同步执行 request")
    }

    /// 后台线程调用：立即返回 true（不等执行完成），request 被派发到主线程执行
    func testDispatchFromBackgroundReturnsImmediatelyAndHopsToMain() {
        let executedOnMain = expectation(description: "request executed on main thread")
        let returnedBeforeExecution = LockedFlag()

        DispatchQueue.global(qos: .userInitiated).async {
            let returnValue = AppOpener.dispatchToMain {
                XCTAssertTrue(Thread.isMainThread, "非主线程调用的 request 应回到主线程执行")
                XCTAssertTrue(
                    returnedBeforeExecution.isSet,
                    "request 执行时调用方早已返回（未被阻塞等待）")
                executedOnMain.fulfill()
            }

            XCTAssertTrue(returnValue)
            returnedBeforeExecution.set()  // dispatchToMain 已返回，request 尚未执行
        }

        wait(for: [executedOnMain], timeout: 5)
    }

    // MARK: - 全局源码守卫

    /// 守卫测试：AppOpener 之外禁止直接调用 NSWorkspace 的同步打开 API。
    ///
    /// 同步调用会在目标应用冷启动期间冻结主线程，导致全局快捷键与面板
    /// 完全无法响应。任何新的"打开"需求必须走 `AppOpener.open`。
    func testNoSynchronousWorkspaceOpenOutsideAppOpener() {
        // 测试文件位于 <repo>/LaunchXTests/，源码位于 <repo>/LaunchX/
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LaunchXTests/
            .deletingLastPathComponent()  // repo root
        let sourceRoot = repoRoot.appendingPathComponent("LaunchX", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceRoot.path))

        var swiftFiles: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.pathExtension == "swift" {
                swiftFiles.append(file)
            }
        }
        XCTAssertGreaterThan(swiftFiles.count, 10, "未能枚举到源码文件，守卫测试无法生效")

        let violations = swiftFiles
            .filter { $0.lastPathComponent != "AppOpener.swift" }  // AppOpener 是唯一合法出口
            .compactMap { file -> String? in
                guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                    return nil
                }
                let hasSyncOpen = content.contains("NSWorkspace.shared.open(")
                let hasOpenApplication = content.contains("NSWorkspace.shared.openApplication")
                let hasLaunchApplication = content.contains("NSWorkspace.shared.launchApplication")
                return (hasSyncOpen || hasOpenApplication || hasLaunchApplication)
                    ? file.lastPathComponent : nil
            }

        XCTAssertTrue(
            violations.isEmpty,
            "发现同步打开调用（会阻塞主线程，冷启动期间快捷键/面板无法响应）：\(violations)。请改用 AppOpener.open")
    }
}

/// RemindersService.openInReminders 的 deep link → 兜底打开 App 逻辑测试。
///
/// openInReminders 为异步实现，"deep link 失败则直接打开提醒事项 App"的
/// 兜底语义通过注入 urlOpener stub 进行验证（不会真的拉起应用）。
final class RemindersOpenFallbackTests: XCTestCase {

    private let service = RemindersService.shared

    override func tearDown() {
        // 恢复生产实现，避免影响其他测试（shared 为进程级单例）
        service.urlOpener = { url, completion in
            _ = AppOpener.open(url, completion: completion)
        }
        super.tearDown()
    }

    /// 带 identifier：先用 x-apple-reminders:// deep link；deep link 失败后兜底打开提醒事项 App
    func testDeepLinkFailureFallsBackToRemindersApp() {
        var opened: [URL] = []
        let expectation = expectation(description: "fallback completed")

        service.urlOpener = { url, completion in
            opened.append(url)
            if url.scheme == "x-apple-reminders" {
                // 模拟 deep link 打开失败
                completion(NSError(domain: "AppOpenerTests", code: 1))
            } else {
                completion(nil)
                expectation.fulfill()
            }
        }

        service.openInReminders(identifier: "test-reminder-id")

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(opened.count, 2, "应恰好尝试 deep link 一次 + 兜底一次")
        XCTAssertEqual(opened[0].scheme, "x-apple-reminders")
        XCTAssertEqual(opened[0].host, "test-reminder-id")
        XCTAssertTrue(opened[1].path.hasSuffix("Reminders.app"), "兜底应打开提醒事项 App 本体")
    }

    /// 不带 identifier：直接打开提醒事项 App，不经过 deep link
    func testNilIdentifierOpensRemindersAppDirectly() {
        var opened: [URL] = []
        service.urlOpener = { url, completion in
            opened.append(url)
            completion(nil)
        }

        service.openInReminders(identifier: nil)

        XCTAssertEqual(opened.count, 1, "无 identifier 时应只打开 App 一次，不做 deep link")
        XCTAssertTrue(opened[0].path.hasSuffix("Reminders.app"))
    }

    /// deep link 成功时不得兜底重复打开 App
    func testDeepLinkSuccessDoesNotFallBack() {
        var opened: [URL] = []
        service.urlOpener = { url, completion in
            opened.append(url)
            completion(nil)
        }

        service.openInReminders(identifier: "another-id")

        XCTAssertEqual(opened.count, 1, "deep link 成功后不应再兜底打开 App")
        XCTAssertEqual(opened[0].scheme, "x-apple-reminders")
    }
}
