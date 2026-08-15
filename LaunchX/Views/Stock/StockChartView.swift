import AppKit
import WebKit

/// K 线图容器：WKWebView 加载本地 chart.html（内联 KLineChart，离线无外部请求）。
/// 数据通过 evaluateJavaScript 桥推送；webview 全生命周期复用。
final class StockChartView: NSView, WKNavigationDelegate, WKScriptMessageHandler {

    private let webView = WKWebView()
    private var chartReady = false
    private var pendingJS: [String] = []

    /// 双击日K某根蜡烛（时间戳毫秒）
    var onDayDoubleClick: ((Int) -> Void)?
    /// 分时模式下点击「复制 Excel」（当天 yyyy-MM-dd）
    var onCopyIntraday: ((String) -> Void)?
    /// 独立分时窗口内点击「关闭」/双击图表
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(
            self, name: "chartDoubleClick")
        webView.configuration.userContentController.add(
            self, name: "chartCopy")
        webView.configuration.userContentController.add(
            self, name: "chartClose")
        // 透明背景以透出面板毛玻璃
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        loadChart()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - JS 消息回调

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "chartDoubleClick":
            if let ts = message.body as? Int { onDayDoubleClick?(ts) }
            else if let ts = message.body as? Double { onDayDoubleClick?(Int(ts)) }
        case "chartCopy":
            if let day = message.body as? String { onCopyIntraday?(day) }
        case "chartClose":
            onClose?()
        default: break
        }
    }

    // MARK: - 加载

    private func loadChart() {
        // 资源会被平铺拷贝进 bundle 根目录（synchronized group 默认行为）
        guard let url = Bundle.main.url(forResource: "chart", withExtension: "html")
            ?? Bundle.main.url(forResource: "chart", withExtension: "html", subdirectory: "StockChart")
        else { NSLog("[StockChartView] chart.html 未打进 bundle"); return }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        chartReady = true
        let queued = pendingJS
        pendingJS.removeAll()
        for js in queued {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 对外接口（主线程调用）

    /// 推入全量 K 线
    func update(bars: [StockDailyBar]) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")

        let payload: [[String: Any]] = bars.enumerated().compactMap { i, bar in
            guard let date = df.date(from: bar.date) else { return nil }
            // 量比 = 当日成交量 / 前 5 日日均量（不足 5 根不显示）
            var volumeRatio = 0.0
            if i >= 5 {
                let avg = bars[(i - 5)..<i].reduce(0) { $0 + $1.volume } / 5
                if avg > 0 { volumeRatio = bar.volume / avg }
            }
            return [
                "timestamp": Int(date.timeIntervalSince1970) * 1000,
                "open": bar.open, "high": bar.high, "low": bar.low, "close": bar.close,
                "volume": bar.volume, "turnover": bar.amount,
                "turnoverRate": bar.turnover, "volumeRatio": volumeRatio,
                // 首根无昨收，null → 图例涨跌幅显示 "--"
                "pct": i == 0 ? NSNull() : bar.pctChange,
            ] as [String: Any]
        }.sorted { ($0["timestamp"] as? Int ?? 0) < ($1["timestamp"] as? Int ?? 0) }
        guard !payload.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            showError("没有可用的 K 线数据")
            return
        }

        eval("updateData(\(jsLiteral(json)), 0)")
    }

    /// 推入某日分时（面积线 + 均价 + 昨收零轴 + 分钟量柱），day 用于顶栏标题与复制；
    /// preClose > 0 时切换百分比轴并画昨收基准线
    func updateIntraday(points: [StockTrendPoint], day: String, preClose: Double = 0) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Asia/Shanghai")

        let payload: [[String: Any]] = points.compactMap { p in
            // 各源时间串可能带秒（"13:50:00"），DateFormatter 严格匹配会解析失败 → 统一截到分钟
            let minute = p.time.count > 16 ? String(p.time.prefix(16)) : p.time
            guard let date = df.date(from: minute) else { return nil }
            return [
                "timestamp": Int(date.timeIntervalSince1970) * 1000,
                "open": p.open, "high": p.high, "low": p.low, "close": p.price,
                "volume": p.volume, "turnover": p.amount,
            ] as [String: Any]
        }
        guard !payload.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            showError("没有可用的分时数据")
            return
        }
        eval("showIntraday(\(jsLiteral(json)), \(jsLiteral(day)), \(preClose))")
    }

    /// 切回日K
    func showDaily() {
        eval("showDaily()")
    }

    /// 独立分时窗口模式（在 updateIntraday 前调用）
    func setStandaloneIntraday() {
        eval("setStandaloneIntraday()")
    }

    func showError(_ message: String) {
        eval("showError(\(jsLiteral(message)))")
    }

    func showHint(_ message: String) {
        eval("showHint(\(jsLiteral(message)))")
    }

    // MARK: - JS 桥

    /// html 未就绪时排队，加载完成后回放
    private func eval(_ js: String) {
        if chartReady {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pendingJS.append(js)
        }
    }

    /// 用 JSON 编码生成合法的 JS 字符串字面量（含引号与转义）
    /// 注意：JSONSerialization 顶层只接受数组/字典，字符串必须走 JSONEncoder
    private func jsLiteral(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
