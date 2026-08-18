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
    private var refreshButton: NSButton?

    /// 点击标题栏刷新按钮：丢弃缓存重新走兜底链（由数据层回填）
    var onRefresh: (() -> Void)?

    /// - Parameter position: 期望的窗口左下角位置（贴股票面板计算得出）；nil 则屏幕居中
    init(
        key: String, day: String, title: String, columns: [String],
        context: StockIntradayContext, position: NSPoint?,
        onRemove: @escaping (String) -> Void
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
            // 刷新按钮（复制按钮左侧）：首点非 09:30 说明拿到的是兜底的粗粒度分钟K，才显示
            let refreshBtn = NSButton(title: "", target: nil, action: nil)
            refreshBtn.bezelStyle = .texturedRounded
            refreshBtn.controlSize = .small
            refreshBtn.image = NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新获取分时")
            refreshBtn.imageScaling = .scaleProportionallyDown
            refreshBtn.toolTip = "重新获取分时（绕过缓存，优先 1 分钟源）"
            refreshBtn.target = self
            refreshBtn.action = #selector(refreshFromTitlebar)
            refreshBtn.frame = NSRect(
                x: titlebarView.bounds.width - 140, y: 3, width: 32, height: 24)
            refreshBtn.autoresizingMask = [.minXMargin]
            refreshBtn.isHidden = true
            titlebarView.addSubview(refreshBtn)
            self.refreshButton = refreshBtn

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

        if let position {
            w.setFrameOrigin(position)
        } else {
            w.center()
        }
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
        refreshButton?.isEnabled = true
        // 1 分钟源（腾讯 minute / 新浪 scale=1 / zzshare）首点都会落在 09:30
        // （后两者会补集合竞价点）；不是 09:30 起步 = 兜底链滑到了粗粒度分钟K
        let firstMinute = points.first.map { String($0.time.dropFirst(11).prefix(5)) } ?? ""
        refreshButton?.isHidden = (firstMinute == "09:30")
    }

    /// 手动刷新开始：按钮去抖 + 图上短暂提示（不清空当前粗粒度图）
    func beginRefresh() {
        refreshButton?.isEnabled = false
        chart.showToast("正在重新获取分时…")
    }

    /// 手动刷新失败：保留当前粗粒度图，仅提示失败原因
    func refreshFailed(message: String) {
        refreshButton?.isEnabled = true
        chart.showToast("刷新失败：\(message)")
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

    /// 标题栏「刷新」按钮：重新走兜底链取 1 分钟分时
    @objc private func refreshFromTitlebar() {
        onRefresh?()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onRemove(key)
    }
}

/// 分时窗口集中管理：多开、去重、关闭时回收
enum StockIntradayWindowManager {
    private static var windows: [String: StockIntradayWindow] = [:]

    /// 打开（或聚焦）某日分时窗口，返回窗口实例供回填数据。
    /// anchor 为股票面板 frame：窗口贴面板摆放（优先右侧、放不下试左侧、再试下方），
    /// 多开时按当前开窗数级联偏移，全部收进屏幕内（旧实现按上一次窗口位置无限级联，会漂出屏幕）。
    @discardableResult
    static func show(
        day: String, code: String, name: String, columns: [String],
        context: StockIntradayContext, anchor: NSRect?
    ) -> StockIntradayWindow {
        let key = "\(code)_\(day)"
        if let existing = windows[key] {
            existing.focus()
            return existing
        }
        let w = StockIntradayWindow(
            key: key, day: day,
            title: "\(name) \(code) · \(day) 分时", columns: columns, context: context,
            position: adjacentPosition(anchor: anchor, size: NSSize(width: 560, height: 400))
        ) { key in
            windows.removeValue(forKey: key)
        }
        windows[key] = w
        return w
    }

    /// 计算贴面板的窗口位置：顶边对齐面板，按已开窗口数级联（关窗自动回缩，不会累积漂移）
    private static func adjacentPosition(anchor: NSRect?, size: NSSize) -> NSPoint? {
        guard let anchor, anchor.width > 0, anchor.height > 0 else { return nil }
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.main
        else { return nil }
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let cascade = CGFloat(windows.count)  // 已开数量 → 偏移份数
        let size = NSSize(
            width: min(size.width, visible.width), height: min(size.height, visible.height))

        let clamp = { (v: CGFloat, lo: CGFloat, hi: CGFloat) in min(max(lo, v), max(lo, hi)) }

        // 横向：优先面板右侧；放不下 → 左侧；两侧都放不下 → 面板列内水平居中
        let rightX = anchor.maxX + gap
        let leftX = anchor.minX - gap - size.width
        let x: CGFloat
        if rightX + size.width <= visible.maxX {
            x = rightX
        } else if leftX >= visible.minX {
            x = leftX
        } else {
            x = clamp(anchor.midX - size.width / 2, visible.minX, visible.maxX - size.width)
        }
        // 纵向：在面板侧边时顶边对齐；落在面板正上/下方时先试下方、放不下再试上方
        let beside = x >= anchor.maxX || x + size.width <= anchor.minX
        let y: CGFloat
        if beside {
            y = anchor.maxY - size.height
        } else {
            y = anchor.minY - gap - size.height >= visible.minY
                ? anchor.minY - gap - size.height : anchor.maxY + gap
        }
        // 级联偏移后整体 clamp 进屏幕
        return NSPoint(
            x: clamp(x + 26 * cascade, visible.minX, visible.maxX - size.width),
            y: clamp(y - 26 * cascade, visible.minY, visible.maxY - size.height))
    }
}
