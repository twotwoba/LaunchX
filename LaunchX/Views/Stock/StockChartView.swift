import AppKit
import WebKit

/// K 线图容器：WKWebView 加载本地 chart.html（内联 KLineChart，离线无外部请求）。
/// 数据通过 evaluateJavaScript 桥推送；webview 全生命周期复用。
final class StockChartView: NSView, WKNavigationDelegate {

    private let webView = WKWebView()
    private var chartReady = false
    private var pendingJS: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
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

        let payload: [[String: Any]] = bars.compactMap { bar in
            guard let date = df.date(from: bar.date) else { return nil }
            return [
                "timestamp": Int(date.timeIntervalSince1970) * 1000,
                "open": bar.open, "high": bar.high, "low": bar.low, "close": bar.close,
                "volume": bar.volume, "turnover": bar.amount,
            ]
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
