import Foundation

// MARK: - 计算历史服务

/// 计算历史:仅「消费结果」时记录(回车复制 / 点击结果复制),最新在前、按表达式去重、上限 100 条。
/// 落盘复用 ClaudeDataStore 的原子写(临时文件 + moveItem),写盘按 1s 防抖合并,
/// 退出/休眠/失活由 AppDelegate flush(saveImmediately)兜底。
final class CalculatorHistoryService {
    static let shared = CalculatorHistoryService()

    /// 历史条数上限
    static let maxEntries = 100

    private let queue = DispatchQueue(label: "com.launchx.calculator.history")
    private let fileURL: URL
    private var entries: [CalculatorHistoryEntry] = []
    private var pendingSaveWorkItem: DispatchWorkItem?

    /// 当前历史(最新在前)
    var currentEntries: [CalculatorHistoryEntry] {
        queue.sync { entries }
    }

    /// - Parameter directory: 持久化目录(默认 App Support/LaunchX/calculator;测试注入临时目录)
    init(directory: URL? = nil) {
        if let directory = directory {
            fileURL = directory.appendingPathComponent("history.json")
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LaunchX/calculator", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            fileURL = base.appendingPathComponent("history.json")
        }
        queue.sync { loadLocked() }
    }

    /// 记录一次计算:同表达式删旧插头置顶,超出上限淘汰尾部
    func record(expression: String, result: String) {
        let expr = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        let res = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty, !res.isEmpty else { return }
        queue.sync {
            entries.removeAll { $0.expression == expr }
            entries.insert(
                CalculatorHistoryEntry(expression: expr, result: res, recordedAt: Date()), at: 0)
            if entries.count > Self.maxEntries {
                entries = Array(entries.prefix(Self.maxEntries))
            }
            scheduleSaveLocked()
        }
    }

    /// 清空全部历史并立即落盘
    func clearAll() {
        queue.sync {
            entries.removeAll()
            saveNowLocked()
        }
    }

    /// 立即落盘(AppDelegate 在 terminate/sleep/resignActive 时调用)
    func saveImmediately() {
        queue.sync { saveNowLocked() }
    }

    // MARK: - 私有(queue 内调用)

    /// 防抖写盘:主线程 1s 合并连续写入(记录频率 = 消费频率,极低频,防抖只为兜底合并)
    private func scheduleSaveLocked() {
        pendingSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveImmediately()
        }
        pendingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveNowLocked() {
        pendingSaveWorkItem?.cancel()
        pendingSaveWorkItem = nil
        try? ClaudeDataStore.shared.writeJSON(entries, to: fileURL)
    }

    private func loadLocked() {
        guard
            let loaded: [CalculatorHistoryEntry] = ClaudeDataStore.shared.readJSON(
                [CalculatorHistoryEntry].self, from: fileURL)
        else { return }
        entries = loaded
    }
}
