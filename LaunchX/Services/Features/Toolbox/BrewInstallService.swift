import AppKit
import Combine
import Darwin
import Foundation

// MARK: - brew 安装状态机

/// 条目安装状态
enum BrewInstallState: Equatable {
    case unknown  // 尚未检查
    case checking  // 正在核对本机是否已装
    case notInstalled  // 未安装
    case installing  // 安装中(排队或运行,区分看 queueItems/currentItemID)
    case installed  // 已安装
    case failed(String)  // 失败(含原因)

    /// 是否处于"占用中"状态(refreshStates 不应覆盖)
    var isBusy: Bool {
        if case .installing = self { return true }
        return false
    }
}

// MARK: - 进程规格与结果(可注入抽象)

/// 一条待执行命令的规格
struct BrewProcessSpec: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]?
}

/// 命令运行结果
struct BrewRunResult: Sendable {
    let exitCode: Int32
    /// 全量输出(stdout+stderr 合并)
    let output: String
    var succeeded: Bool { exitCode == 0 }
}

/// 进程句柄(取消用)
final class BrewProcessHandle {
    private let lock = NSLock()
    nonisolated(unsafe) private var process: Process?

    nonisolated func bind(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    /// 温和取消:先 terminate;brew 会派生子进程,2 秒后仍存活则 SIGKILL 强杀
    nonisolated func requestCancel() {
        lock.lock()
        let target = process
        lock.unlock()
        guard let target, target.isRunning else { return }
        target.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            if target.isRunning {
                // Process 无 kill API,经 pid 发 SIGKILL
                kill(target.processIdentifier, SIGKILL)
            }
        }
    }
}

/// 命令运行抽象(单测注入 stub;严禁单测真实 spawn brew)
protocol BrewCommandRunning: Sendable {
    /// 流式执行:输出增量经 onOutput 回调(任意线程),结束经 completion 回调一次
    nonisolated func run(
        spec: BrewProcessSpec,
        onOutput: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (BrewRunResult) -> Void
    ) -> BrewProcessHandle
}

/// 真实实现:Process + 合并管道(stdout/stderr 同管道)+ 可读流式回调
final class RealBrewCommandRunner: BrewCommandRunning {
    nonisolated func run(
        spec: BrewProcessSpec,
        onOutput: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable (BrewRunResult) -> Void
    ) -> BrewProcessHandle {
        let handle = BrewProcessHandle()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        if let extra = spec.environment {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in extra {
                environment[key] = value
            }
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe  // 合并 stderr,便于错误识别与日志展示

        let bufferLock = NSLock()
        nonisolated(unsafe) var accumulated = ""

        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            bufferLock.lock()
            accumulated += chunk
            bufferLock.unlock()
            onOutput(chunk)
        }

        process.terminationHandler = { terminated in
            pipe.fileHandleForReading.readabilityHandler = nil
            // 收尾读取管道残余(terminationHandler 触发时可能还有未读数据)
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty {
                let chunk = String(data: rest, encoding: .utf8) ?? ""
                bufferLock.lock()
                accumulated += chunk
                bufferLock.unlock()
                onOutput(chunk)
            }
            bufferLock.lock()
            let output = accumulated
            bufferLock.unlock()
            completion(BrewRunResult(exitCode: terminated.terminationStatus, output: output))
        }

        do {
            try process.run()
            handle.bind(process)
        } catch {
            // 启动失败(如可执行文件不存在):立即以 -1 结束
            pipe.fileHandleForReading.readabilityHandler = nil
            completion(
                BrewRunResult(exitCode: -1, output: "无法启动进程:\(error.localizedDescription)"))
        }
        return handle
    }
}

// MARK: - 安装执行器

/// brew 一键安装执行器
///
/// - 串行队列一次只跑一个 brew install(Homebrew 自身有锁,并发必挂),其余排队
/// - 日志尾部 200 行、0.5 秒节流刷新到 currentLogTail
/// - 取消:terminate → 2 秒后仍活 kill;排队中的直接出队
/// - cask 需要管理员密码时:二次确认后经 osascript 提权重试(包名已过白名单校验)
/// - 完成提示:NSAlert(项目现有完成反馈惯例;系统通知留作后续增强)
final class BrewInstallService: ObservableObject {
    static let shared = BrewInstallService(runner: RealBrewCommandRunner())

    // MARK: - 对 UI 发布的状态(全部主线程写入)

    /// 各条目安装状态
    @Published private(set) var states: [UUID: BrewInstallState] = [:]
    /// 排队等待中的条目
    @Published private(set) var queueItems: [UUID] = []
    /// 当前正在安装的条目
    @Published private(set) var currentItemID: UUID?
    /// 当前安装日志尾部(节流刷新)
    @Published private(set) var currentLogTail: String = ""

    // MARK: - 内部状态

    private let runner: BrewCommandRunning
    /// brew 路径探测(可注入:测试机不一定安装了 brew)
    private let brewPathProvider: () -> String?

    /// 排队等待的条目(与 queueItems 一一对应;仅主线程读写)
    nonisolated(unsafe) private var pendingItems: [ToolboxItem] = []

    private let lock = NSLock()
    nonisolated(unsafe) private var activeHandles: [UUID: BrewProcessHandle] = [:]
    nonisolated(unsafe) private var cancelRequested: Set<UUID> = []
    // 日志缓冲与节流标记
    nonisolated(unsafe) private var logBuffer = ""
    nonisolated(unsafe) private var logFlushScheduled = false

    private let maxLogLines = 200

    /// 完成提示开关(单测必须关闭:NSAlert.runModal 会卡住无交互的测试进程)
    nonisolated(unsafe) var alertsEnabled = true

    init(
        runner: BrewCommandRunning,
        brewPathProvider: @escaping () -> String? = { BrewPathResolver.resolve() }
    ) {
        self.runner = runner
        self.brewPathProvider = brewPathProvider
    }

    // MARK: - 入队

    /// 入队安装一个 brew 包(白名单校验失败直接置 failed)
    /// 串行模型:一次只跑一个 brew install(Homebrew 自身有锁),完成回调里再启动下一个
    func enqueue(item: ToolboxItem) {
        guard item.kind == .brewPackage, let brewKind = item.brewKind else {
            setState(item.id, .failed("条目不是 brew 包"))
            return
        }
        // 包名白名单(shell 注入防护;tap 前缀允许 "/")
        let fullName = item.brewTap.map { "\($0)/\(item.name)" } ?? item.name
        guard BrewfileParser.isValidName(fullName) else {
            setState(item.id, .failed("包名不合法:\(fullName)"))
            return
        }
        guard brewPathProvider() != nil else {
            setState(item.id, .failed(BrewService.BrewServiceError.brewNotFound.localizedDescription))
            return
        }
        // 防重复入队
        if let current = states[item.id], current.isBusy {
            return
        }

        setState(item.id, .installing)
        if currentItemID != nil {
            // 已有安装在进行:排队
            pendingItems.append(item)
            queueItems.append(item.id)
        } else {
            beginInstall(item)
        }
    }

    // MARK: - 取消

    /// 取消安装:运行中的 terminate 进程;排队中的直接出队
    func cancel(itemID: UUID) {
        lock.lock()
        cancelRequested.insert(itemID)
        let handle = activeHandles[itemID]
        lock.unlock()

        if currentItemID == itemID {
            handle?.requestCancel()  // 结束状态由 completion 统一处理并触发下一个
        } else if let pendingIndex = pendingItems.firstIndex(where: { $0.id == itemID }) {
            // 排队中:直接出队,恢复未安装状态
            pendingItems.remove(at: pendingIndex)
            queueItems.removeAll { $0 == itemID }
            clearCancel(itemID)
            setState(itemID, .notInstalled)
        }
    }

    // MARK: - 状态刷新

    /// 批量核对本机已装状态(后台 brew list,主线程批量落状态)
    func refreshStates(items: [ToolboxItem]) {
        let brewItems = items.filter { $0.kind == .brewPackage }
        guard !brewItems.isEmpty else { return }
        guard BrewPathResolver.resolve() != nil else {
            // 未装 Homebrew:交给 UI 顶部提示,状态保持 unknown
            return
        }

        // 只覆盖非占用状态
        let checkable = brewItems.filter { !isBusyState($0.id) }
        guard !checkable.isEmpty else { return }
        for item in checkable {
            setState(item.id, .checking)
        }

        Task {
            let sets = try? await BrewService.shared.fetchInstalledSets()
            guard let sets else {
                for item in checkable where state(of: item.id) == .checking {
                    setState(item.id, .unknown)
                }
                return
            }
            for item in checkable {
                let name = item.name
                let installed =
                    (item.brewKind == .cask ? sets.casks.contains(name) : sets.formulas.contains(name))
                setState(item.id, installed ? .installed : .notInstalled)
            }
        }
    }

    // MARK: - 执行核心

    /// 启动一次安装(主线程门闸:currentItemID 非空期间不再启动新任务;
    /// 进程 spawn 与流式读取放后台线程)
    private func beginInstall(_ item: ToolboxItem) {
        guard let brewKind = item.brewKind else {
            currentItemID = nil
            setState(item.id, .failed("条目不是 brew 包"))
            startNext()
            return
        }
        let fullName = item.brewTap.map { "\($0)/\(item.name)" } ?? item.name
        guard let brewPath = brewPathProvider() else {
            currentItemID = nil
            setState(item.id, .failed(BrewService.BrewServiceError.brewNotFound.localizedDescription))
            startNext()
            return
        }

        currentItemID = item.id
        resetLog()

        let arguments: [String] =
            brewKind == .cask ? ["install", "--cask", fullName] : ["install", fullName]
        let spec = BrewProcessSpec(
            executablePath: brewPath,
            arguments: arguments,
            environment: BrewService.childEnvironment(brewPath: brewPath))
        let itemID = item.id
        let name = item.name

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // spawn 前已取消:直接结束,不发起命令
            if self.isCancelled(itemID) {
                DispatchQueue.main.async {
                    self.finishCurrent(itemID: itemID, state: .failed("已取消"))
                    self.startNext()
                }
                return
            }
            let handle = self.runner.run(
                spec: spec,
                onOutput: { [weak self] chunk in
                    self?.appendLog(chunk)
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        self?.handleCompletion(
                            result: result, itemID: itemID, name: name, fullName: fullName,
                            isCask: brewKind == .cask, brewPath: brewPath,
                            attemptedElevated: false)
                    }
                })
            self.setHandle(itemID, handle)
            // spawn 与入表之间的小窗口内取消:补一发取消
            if self.isCancelled(itemID) {
                handle.requestCancel()
            }
        }
    }

    /// 当前任务终结后的收尾(主线程):清句柄/标记并触发下一个
    private func finishCurrent(itemID: UUID, state: BrewInstallState) {
        clearHandle(itemID)
        clearCancel(itemID)
        currentItemID = nil
        setState(itemID, state)
    }

    /// 启动下一个排队任务(主线程)
    private func startNext() {
        guard currentItemID == nil, !pendingItems.isEmpty else { return }
        let next = pendingItems.removeFirst()
        queueItems.removeFirst()
        beginInstall(next)
    }

    /// 安装结束处理(主线程):终结当前任务并在所有终态路径上触发下一个
    private func handleCompletion(
        result: BrewRunResult, itemID: UUID, name: String, fullName: String, isCask: Bool,
        brewPath: String, attemptedElevated: Bool
    ) {
        // 用户已取消
        if isCancelled(itemID) {
            finishCurrent(itemID: itemID, state: .failed("已取消"))
            startNext()
            return
        }

        if result.succeeded {
            finishCurrent(itemID: itemID, state: .installed)
            if alertsEnabled {
                ToolboxAlerts.showOnMain(
                    title: "安装完成",
                    message: "\(name) 已通过 Homebrew 安装成功。")
            }
            startNext()
            return
        }

        // cask 首次失败且疑似需要管理员权限 → 二次确认后提权重试
        if !attemptedElevated, isCask, Self.looksLikeSudoFailure(result.output) {
            let confirmed = Self.showElevationConfirmation(command: "brew install --cask \(fullName)")
            if confirmed {
                // 提权重试期间保持占用,由其 completion 触发 startNext
                performElevatedRetry(
                    itemID: itemID, name: name, fullName: fullName, brewPath: brewPath)
                return
            }
            finishCurrent(itemID: itemID, state: .failed("已取消"))
            startNext()
            return
        }

        finishCurrent(
            itemID: itemID, state: .failed("安装失败(exit \(result.exitCode)),详情见安装日志"))
        if alertsEnabled {
            ToolboxAlerts.showOnMain(
                title: "安装失败",
                message: "\(name) 安装失败(exit \(result.exitCode))。\n可在下方「安装日志」查看详情。",
                style: .warning)
        }
        startNext()
    }

    /// 提权重试(osascript administrator privileges)
    private func performElevatedRetry(itemID: UUID, name: String, fullName: String, brewPath: String) {
        // fullName 已过 BrewfileParser.isValidName 白名单,可安全拼入 shell 字符串
        let shellCommand = "\(brewPath) install --cask '\(fullName)'"
        let script = "do shell script \"\(shellCommand)\" with administrator privileges"
        let spec = BrewProcessSpec(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            environment: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let handle = self.runner.run(
                spec: spec,
                onOutput: { [weak self] chunk in
                    self?.appendLog(chunk)
                },
                completion: { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if self.isCancelled(itemID) {
                            self.finishCurrent(itemID: itemID, state: .failed("已取消"))
                        } else if result.succeeded {
                            self.finishCurrent(itemID: itemID, state: .installed)
                            if self.alertsEnabled {
                                ToolboxAlerts.showOnMain(
                                    title: "安装完成", message: "\(name) 已通过 Homebrew 安装成功。")
                            }
                        } else {
                            self.finishCurrent(
                                itemID: itemID,
                                state: .failed("提权安装失败(exit \(result.exitCode)),详情见安装日志"))
                            if self.alertsEnabled {
                                ToolboxAlerts.showOnMain(
                                    title: "安装失败",
                                    message:
                                        "\(name) 提权安装失败(exit \(result.exitCode))。\n可在下方「安装日志」查看详情。",
                                    style: .warning)
                            }
                        }
                        self.startNext()
                    }
                })
            self.setHandle(itemID, handle)
            if self.isCancelled(itemID) {
                handle.requestCancel()
            }
        }
    }

    // MARK: - 判定辅助

    /// stderr/stdout 是否疑似需要 sudo(常见于部分 cask 的 installer 阶段)
    nonisolated static func looksLikeSudoFailure(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("sudo") || lowered.contains("root")
            || lowered.contains("administrator") || lowered.contains("osascript")
    }

    /// 提权二次确认(照 SystemCommandService 危险命令二次确认惯例,主线程 runModal)
    nonisolated private static func showElevationConfirmation(command: String) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                showElevationConfirmation(command: command)
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "该 Cask 需要管理员权限"
        alert.informativeText =
            "安装此 Cask 需要执行:\n\(command)\n\n确认后将弹出系统授权框(输入开机密码),是否继续?"
        alert.addButton(withTitle: "提权继续")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - 状态/句柄/日志的线程安全小工具

    private func setState(_ id: UUID, _ state: BrewInstallState) {
        if Thread.isMainThread {
            states[id] = state
        } else {
            DispatchQueue.main.async { self.states[id] = state }
        }
    }

    private func state(of id: UUID) -> BrewInstallState {
        states[id] ?? .unknown
    }

    private func isBusyState(_ id: UUID) -> Bool {
        state(of: id).isBusy
    }

    private func setHandle(_ id: UUID, _ handle: BrewProcessHandle) {
        lock.lock()
        defer { lock.unlock() }
        activeHandles[id] = handle
    }

    private func clearHandle(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activeHandles.removeValue(forKey: id)
    }

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelRequested.contains(id)
    }

    private func clearCancel(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested.remove(id)
    }

    // MARK: - 日志(nonisolated,后台线程追加,0.5s 节流刷主线程)

    nonisolated private func resetLog() {
        lock.lock()
        logBuffer = ""
        lock.unlock()
        DispatchQueue.main.async { self.currentLogTail = "" }
    }

    nonisolated private func appendLog(_ chunk: String) {
        lock.lock()
        logBuffer += chunk
        let scheduled = logFlushScheduled
        if !scheduled {
            logFlushScheduled = true
        }
        lock.unlock()
        guard !scheduled else { return }
        // 0.5 秒节流:高频输出时避免每行都触发 SwiftUI 刷新
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.logFlushScheduled = false
            let text = self.logBuffer
            self.lock.unlock()
            // 只保留尾部 maxLogLines 行
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(self.maxLogLines).joined(separator: "\n")
            self.currentLogTail = tail
        }
    }
}
