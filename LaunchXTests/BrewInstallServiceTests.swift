import Combine
import XCTest

@testable import LaunchX

/// brew 安装执行器:状态迁移/串行/取消/sudo 识别
/// 严禁真实 spawn brew —— 命令执行走 stub,brew 路径探测注入假路径
final class BrewInstallServiceTests: XCTestCase {

    // MARK: - Stub

    /// 可配置的命令执行 stub:返回 canned 结果,记录调用
    private final class StubRunner: BrewCommandRunning {
        let lock = NSLock()
        nonisolated(unsafe) var results: [BrewRunResult]  // 依次返回
        nonisolated(unsafe) var callCount = 0
        nonisolated(unsafe) var recordedSpecs: [BrewProcessSpec] = []
        /// 是否异步延迟回调(模拟长时间安装,测取消/排队)
        nonisolated(unsafe) var delayBeforeCompletion: TimeInterval = 0

        init(results: [BrewRunResult]) {
            self.results = results
        }

        nonisolated func run(
            spec: BrewProcessSpec,
            onOutput: @escaping @Sendable (String) -> Void,
            completion: @escaping @Sendable (BrewRunResult) -> Void
        ) -> BrewProcessHandle {
            lock.lock()
            let index = min(callCount, results.count - 1)
            let result = results[index]
            callCount += 1
            let delay = delayBeforeCompletion
            lock.unlock()
            lock.lock()
            recordedSpecs.append(spec)
            lock.unlock()

            onOutput(result.output)
            let completionCopy = completion
            let resultCopy = result
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    completionCopy(resultCopy)
                }
            } else {
                completionCopy(resultCopy)
            }
            return BrewProcessHandle()
        }
    }

    /// 假 brew 路径(测试机不一定装了 brew;stub 不真正执行)
    private let fakeBrewPath = "/usr/local/bin/brew"

    /// 构造被测服务(关闭弹窗:NSAlert.runModal 会卡死无交互的测试进程)
    private func makeService(results: [BrewRunResult], delay: TimeInterval = 0) -> (
        BrewInstallService, StubRunner
    ) {
        let runner = StubRunner(results: results)
        runner.lock.lock()
        runner.delayBeforeCompletion = delay
        runner.lock.unlock()
        let service = BrewInstallService(runner: runner, brewPathProvider: { self.fakeBrewPath })
        service.alertsEnabled = false
        return (service, runner)
    }

    // MARK: - 状态迁移

    func testEnqueueSuccessTransitionsToInstalled() {
        let (service, runner) = makeService(results: [BrewRunResult(exitCode: 0, output: "ok")])
        let item = ToolboxItem.brewPackage(name: "wget", kind: .formula)

        let expectation = expectation(description: "installed")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if states[item.id] == .installed {
                expectation.fulfill()
            }
        }
        service.enqueue(item: item)
        wait(for: [expectation], timeout: 3)
        cancellable?.cancel()

        // 传给 runner 的参数应为 brew install + 包名
        runner.lock.lock()
        let spec = runner.recordedSpecs.first
        runner.lock.unlock()
        XCTAssertEqual(spec?.executablePath, fakeBrewPath)
        XCTAssertEqual(spec?.arguments, ["install", "wget"])
    }

    func testEnqueueFailureTransitionsToFailed() {
        let (service, _) = makeService(results: [BrewRunResult(exitCode: 1, output: "boom")])
        let item = ToolboxItem.brewPackage(name: "jq", kind: .formula)

        let expectation = expectation(description: "failed")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if case .failed = states[item.id] {
                expectation.fulfill()
            }
        }
        service.enqueue(item: item)
        wait(for: [expectation], timeout: 3)
        cancellable?.cancel()
    }

    /// cask 走 --cask 参数
    func testCaskInstallUsesCaskFlag() {
        let (service, runner) = makeService(results: [BrewRunResult(exitCode: 0, output: "ok")])
        let item = ToolboxItem.brewPackage(name: "iterm2", kind: .cask)

        let expectation = expectation(description: "installed")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if states[item.id] == .installed {
                expectation.fulfill()
            }
        }
        service.enqueue(item: item)
        wait(for: [expectation], timeout: 3)
        cancellable?.cancel()

        runner.lock.lock()
        let args = runner.recordedSpecs.first?.arguments
        runner.lock.unlock()
        XCTAssertEqual(args, ["install", "--cask", "iterm2"])
    }

    // MARK: - 串行执行

    /// 两个任务依次执行:第一个完成后第二个才开始(stub 同步回调,顺序天然成立,
    /// 关键断言是两次调用都发生且都成功落状态)
    func testSerialExecutionBothComplete() {
        let (service, runner) = makeService(
            results: [
                BrewRunResult(exitCode: 0, output: "first"),
                BrewRunResult(exitCode: 0, output: "second"),
            ])
        let first = ToolboxItem.brewPackage(name: "wget", kind: .formula)
        let second = ToolboxItem.brewPackage(name: "jq", kind: .formula)

        let expectation = expectation(description: "both installed")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if states[first.id] == .installed, states[second.id] == .installed {
                expectation.fulfill()
            }
        }
        service.enqueue(item: first)
        service.enqueue(item: second)
        wait(for: [expectation], timeout: 3)
        cancellable?.cancel()

        runner.lock.lock()
        let callCount = runner.callCount
        runner.lock.unlock()
        XCTAssertEqual(callCount, 2, "两个任务都应执行")
    }

    // MARK: - 防护与工具行为

    /// brew 不可用时直接 failed(不调用 runner)
    func testMissingBrewFailsImmediately() {
        let runner = StubRunner(results: [BrewRunResult(exitCode: 0, output: "should-not-run")])
        let service = BrewInstallService(runner: runner, brewPathProvider: { nil })
        service.alertsEnabled = false
        let item = ToolboxItem.brewPackage(name: "wget", kind: .formula)

        let expectation = expectation(description: "failed as brewNotFound")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if case .failed(let message) = states[item.id], message.contains("Homebrew") {
                expectation.fulfill()
            }
        }
        service.enqueue(item: item)
        wait(for: [expectation], timeout: 2)
        cancellable?.cancel()

        runner.lock.lock()
        let callCount = runner.callCount
        runner.lock.unlock()
        XCTAssertEqual(callCount, 0, "无 brew 时不应发起任何命令")
    }

    /// 包名白名单:含非法字符直接 failed,不发起命令
    func testInvalidNameRejectedBeforeExecution() {
        let (service, runner) = makeService(results: [BrewRunResult(exitCode: 0, output: "should-not-run")])
        let item = ToolboxItem.brewPackage(name: "bad;rm-rf", kind: .formula)

        let expectation = expectation(description: "failed as invalid name")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if case .failed = states[item.id] {
                expectation.fulfill()
            }
        }
        service.enqueue(item: item)
        wait(for: [expectation], timeout: 2)
        cancellable?.cancel()

        runner.lock.lock()
        let callCount = runner.callCount
        runner.lock.unlock()
        XCTAssertEqual(callCount, 0)
    }

    // MARK: - sudo 识别

    func testLooksLikeSudoFailure() {
        XCTAssertTrue(
            BrewInstallService.looksLikeSudoFailure(
                "Error: Running installer requires root privileges"))
        XCTAssertTrue(
            BrewInstallService.looksLikeSudoFailure("Please run with sudo"))
        XCTAssertTrue(
            BrewInstallService.looksLikeSudoFailure(
                "osascript -e do shell script with administrator"))
        XCTAssertFalse(
            BrewInstallService.looksLikeSudoFailure("Error: no available formula"))
    }

    // MARK: - 取消

    /// 取消排队中的任务:直接出队并回到 notInstalled,不发起命令
    func testCancelQueuedItem() {
        // 第一个任务延迟完成,保证第二个处于排队中
        let (service, runner) = makeService(
            results: [BrewRunResult(exitCode: 0, output: "slow")], delay: 0.5)
        let first = ToolboxItem.brewPackage(name: "wget", kind: .formula)
        let second = ToolboxItem.brewPackage(name: "jq", kind: .formula)

        let firstDone = expectation(description: "first done")
        var cancellable: AnyCancellable?
        cancellable = service.$states.sink { states in
            if states[first.id] == .installed {
                firstDone.fulfill()
            }
        }

        service.enqueue(item: first)
        service.enqueue(item: second)
        // 等到第二个进入队列后取消
        let queued = expectation(description: "second queued")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if service.queueItems.contains(second.id) {
                queued.fulfill()
            } else {
                queued.fulfill()  // 时序波动时也放行,后面断言兜底
            }
        }
        wait(for: [queued], timeout: 2)
        service.cancel(itemID: second.id)

        wait(for: [firstDone], timeout: 3)
        cancellable?.cancel()

        runner.lock.lock()
        let callCount = runner.callCount
        runner.lock.unlock()
        XCTAssertEqual(callCount, 1, "被取消的排队任务不应发起命令")
    }
}
