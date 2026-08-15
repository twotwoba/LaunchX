import AppKit

/// 单个分时窗口：标题栏窗口 + 内嵌 StockChartView（独立分时态）。
/// 先开窗显示「正在查询」，数据到达后渲染；同一 (code, day) 复用，不同日期可多开比对。
final class StockIntradayWindow: NSObject, NSWindowDelegate {

    private(set) var window: NSWindow?
    private let chart: StockChartView
    private let day: String
    private let key: String
    private let columns: [String]
    private let context: StockIntradayContext
    private let onRemove: (String) -> Void
    private var points: [StockTrendPoint] = []

    init(
        key: String, day: String, title: String, columns: [String],
        context: StockIntradayContext, onRemove: @escaping (String) -> Void
    ) {
        self.key = key
        self.day = day
        self.columns = columns
        self.context = context
        self.onRemove = onRemove
        self.chart = StockChartView(frame: .zero)
        super.init()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = title
        w.delegate = self
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 380, height: 260)

        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.onCopyIntraday = { [weak self] day in self?.copyExcel(day: day) }
        chart.onClose = { [weak self] in self?.window?.close() }
        w.contentView = chart

        // 复制按钮放标题栏右侧：图内右下角的百分比轴刻度会被遮挡
        if let titlebarView = w.standardWindowButton(.closeButton)?.superview {
            let btn = NSButton(title: "复制 Excel", target: nil, action: nil)
            btn.bezelStyle = .texturedRounded
            btn.controlSize = .small
            btn.font = .systemFont(ofSize: 11, weight: .medium)
            btn.target = self
            btn.action = #selector(copyExcelFromTitlebar)
            btn.frame = NSRect(x: titlebarView.bounds.width - 104, y: 3, width: 92, height: 24)
            btn.autoresizingMask = [.minXMargin]
            titlebarView.addSubview(btn)
        }

        // html 加载完成前 eval 会排队，顺序即调用顺序；先声明独立分时态再进数据
        chart.setStandaloneIntraday()
        chart.showHint("正在查询 \(day) 分时…")

        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func focus() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// 数据到达：渲染分时图（昨收已知时启用百分比轴 + 零轴基准线）
    func render(points: [StockTrendPoint]) {
        self.points = points
        chart.updateIntraday(points: points, day: day, preClose: context.preClose ?? 0)
    }

    /// 查询失败：错误显示在分时窗口内（窗口保留，用户可关闭）
    func fail(message: String) {
        chart.showError(message)
    }

    /// 复制 Excel：这一天汇总为一条（开高低收/均价/总量/额/涨跌幅/量比/换手率），多天可堆叠比对
    private func copyExcel(day: String) {
        guard day == self.day, !points.isEmpty else { return }
        StockExporter.copyIntradayDay(points: points, day: day, columns: columns, context: context)
    }

    /// 标题栏「复制 Excel」按钮（图内按钮已隐藏，避免遮挡百分比刻度）
    @objc private func copyExcelFromTitlebar() {
        guard !points.isEmpty else { return }
        StockExporter.copyIntradayDay(points: points, day: day, columns: columns, context: context)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onRemove(key)
    }
}

/// 分时窗口集中管理：多开、去重、关闭时回收
enum StockIntradayWindowManager {
    private static var windows: [String: StockIntradayWindow] = [:]
    private static var cascadeOrigin: NSPoint?

    /// 打开（或聚焦）某日分时窗口，返回窗口实例供回填数据
    @discardableResult
    static func show(
        day: String, code: String, name: String, columns: [String],
        context: StockIntradayContext
    ) -> StockIntradayWindow {
        let key = "\(code)_\(day)"
        if let existing = windows[key] {
            existing.focus()
            return existing
        }
        let w = StockIntradayWindow(
            key: key, day: day,
            title: "\(name) \(code) · \(day) 分时", columns: columns, context: context
        ) { key in
            windows.removeValue(forKey: key)
        }
        // 多开时级联排布，避免完全重叠
        if let origin = cascadeOrigin {
            w.window?.setFrameOrigin(NSPoint(x: origin.x + 28, y: max(40, origin.y - 28)))
        }
        cascadeOrigin = w.window?.frame.origin
        windows[key] = w
        return w
    }
}
