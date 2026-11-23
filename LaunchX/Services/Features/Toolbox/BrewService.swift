import Foundation

// MARK: - brew 可执行路径探测
//
// GUI 应用不继承 shell 的 PATH(.zshrc 等不生效),必须显式探测 brew 位置:
// Apple Silicon 在 /opt/homebrew/bin/brew,Intel 在 /usr/local/bin/brew,
// 迁移过的机器可能两者并存,按顺序取第一个存在的。
enum BrewPathResolver {
    /// 常见安装路径(顺序即优先级)
    static let defaultCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private static let lock = NSLock()
    // 探测结果缓存:nil=未探测,.some(nil)=已探测但未找到(避免重复扫描)
    nonisolated(unsafe) private static var cached: String?? = nil

    /// 解析 brew 路径;extraCandidates 供测试注入,优先于默认候选
    nonisolated static func resolve(extraCandidates: [String] = []) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached {
            return cached
        }
        let found = (extraCandidates + defaultCandidates).first { candidate in
            FileManager.default.isExecutableFile(atPath: candidate)
        }
        cached = .some(found)
        return found
    }

    /// 清除缓存(测试或安装 brew 后调用)
    nonisolated static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }
}

// MARK: - Homebrew 服务
//
/// 负责:brew 路径解析、本机已装列表一键导入、安装状态检查。
/// 命令执行照 IDERecentProjectsService.runCommand 惯例(先读管道防互锁),
/// 放在后台队列执行并回调主线程(照 SystemCommandService 模式)。
final class BrewService {
    static let shared = BrewService()

    private init() {}

    // MARK: - 错误

    enum BrewServiceError: LocalizedError {
        case brewNotFound  // 未检测到 Homebrew

        var errorDescription: String? {
            switch self {
            case .brewNotFound:
                return "未检测到 Homebrew,请先安装(https://brew.sh)"
            }
        }
    }

    /// 导入结果
    struct ImportResult {
        var items: [ToolboxItem]
        var skippedMasCount: Int  // 忽略的 Mac App Store(mas)条目数
        var source: ImportSource

        enum ImportSource: Equatable {
            case bundleDump  // brew bundle dump --file=-(首选)
            case listOutput  // brew list(老版本回退)
        }
    }

    // MARK: - 路径

    /// 当前 brew 路径(探测结果有缓存)
    func brewPath() -> String? {
        BrewPathResolver.resolve()
    }

    // MARK: - 一键导入本机已装列表

    /// 导入本机已装 formula/cask(后台执行)。
    /// 首选 `brew bundle dump --file=-`(一次拿全 formula/cask/tap);
    /// 老版本 brew 无 bundle 子命令时回退 `brew list --formula/--cask`。
    func importInstalled() async throws -> ImportResult {
        guard let brewPath = brewPath() else {
            throw BrewServiceError.brewNotFound
        }
        return try await runInBackground {
            try BrewService.importInstalledBlocking(brewPath: brewPath)
        }
    }

    // MARK: - 安装状态检查

    /// 拉取本机已装集合(供 BrewInstallService.refreshStates 批量核对)
    func fetchInstalledSets() async throws -> (formulas: Set<String>, casks: Set<String>) {
        guard let brewPath = brewPath() else {
            throw BrewServiceError.brewNotFound
        }
        return try await runInBackground {
            try BrewService.fetchInstalledSetsBlocking(brewPath: brewPath)
        }
    }

    // MARK: - 后台执行核心(nonisolated,可在任意线程调用)

    nonisolated private static func importInstalledBlocking(brewPath: String) throws -> ImportResult {
        // 首选:brew bundle dump --file=- 输出到 stdout
        if let text = try? runCommand(
            brewPath, arguments: ["bundle", "dump", "--file=-"],
            env: childEnvironment(brewPath: brewPath))
        {
            let entries = BrewfileParser.parse(text)
            let masCount = BrewfileParser.countMasEntries(text)
            return ImportResult(
                items: items(from: entries), skippedMasCount: masCount, source: .bundleDump)
        }
        // 回退:brew list(无 tap 信息)
        let formulas =
            (try? runCommand(
                brewPath, arguments: ["list", "--formula"],
                env: childEnvironment(brewPath: brewPath))) ?? ""
        let casks =
            (try? runCommand(
                brewPath, arguments: ["list", "--cask"],
                env: childEnvironment(brewPath: brewPath))) ?? ""
        let entries =
            BrewfileParser.parseListOutput(formulas, kind: .formula)
            + BrewfileParser.parseListOutput(casks, kind: .cask)
        return ImportResult(items: items(from: entries), skippedMasCount: 0, source: .listOutput)
    }

    nonisolated private static func fetchInstalledSetsBlocking(brewPath: String) throws
        -> (formulas: Set<String>, casks: Set<String>)
    {
        let env = childEnvironment(brewPath: brewPath)
        let formulas =
            (try? runCommand(brewPath, arguments: ["list", "--formula"], env: env)) ?? ""
        let casks = (try? runCommand(brewPath, arguments: ["list", "--cask"], env: env)) ?? ""
        return (
            Set(BrewfileParser.parseListOutput(formulas, kind: .formula).map(\.name)),
            Set(BrewfileParser.parseListOutput(casks, kind: .cask).map(\.name))
        )
    }

    /// 条目转 ToolboxItem(按名字排序)
    nonisolated private static func items(from entries: [BrewfileParser.Entry]) -> [ToolboxItem] {
        entries
            .map { ToolboxItem.brewPackage(name: $0.name, kind: $0.kind, tap: $0.tap) }
            .sorted { $0.name < $1.name }
    }

    /// 子进程环境:GUI 下不继承 shell PATH,显式注入 brew bin + 系统路径;禁止自动 update 加速安装
    nonisolated static func childEnvironment(brewPath: String) -> [String: String] {
        let brewBin = (brewPath as NSString).deletingLastPathComponent
        return [
            "PATH": "\(brewBin):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
    }

    /// 同步执行命令,返回 stdout(仿 IDERecentProjectsService.runCommand:先读管道再 waitExit 防互锁)
    nonisolated static func runCommand(
        _ executablePath: String, arguments: [String], env: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                environment[key] = value
            }
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        // 先持续读取 stdout,避免子进程在管道缓冲区写满后阻塞,导致 waitUntilExit 互锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BrewCommandError.nonZeroExit(code: process.terminationStatus)
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw BrewCommandError.invalidUTF8
        }
        return output
    }
}

/// brew 命令错误
enum BrewCommandError: LocalizedError {
    case nonZeroExit(code: Int32)
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code): return "brew 命令执行失败(exit \(code))"
        case .invalidUTF8: return "brew 命令输出包含无效 UTF-8"
        }
    }
}

// MARK: - 后台执行辅助

/// 把同步阻塞闭包丢到全局后台队列执行(async/await 桥接,照 SystemCommandService 的后台惯例)
func runInBackground<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
