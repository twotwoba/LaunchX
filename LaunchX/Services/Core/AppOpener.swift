import AppKit

// MARK: - 统一的「打开 URL / 启动应用」异步入口
//
// 为什么存在：`NSWorkspace.shared.open(_:)`（以及 `open(_:withApplicationAt:configuration:)`
// 不带 completionHandler 的重载）是【同步】调用 —— 打开应用时会一直阻塞调用线程，
// 直到 LaunchServices 报告目标应用完成启动。冷启动重型应用（Xcode、JetBrains、
// 首次启动的浏览器等）可轻易阻塞数秒到数十秒；而 LaunchX 的全局快捷键
// （Carbon 事件循环）与面板显示全部依赖主线程，主线程一旦被同步 open 卡住，
// 用户在该应用的整个启动期间都无法再次唤起 LaunchX。
//
// 因此所有「打开」操作统一走本入口：内部使用 macOS 10.15+ 的异步 API
// `open(_:configuration:completionHandler:)`，调用立即返回，实际启动由系统在
// 后台完成并在结束时回调。相比旧实现（asyncAfter + 同步 open）无新增线程、
// 无轮询、无额外开销。
//
// 约定：
// 1. 除本文件外，禁止直接调用 `NSWorkspace.shared.open(`（由
//    AppOpenerTests 的源码守卫测试强制约束）。
// 2. 单元测试中严禁真实调用本入口去打开任何 URL（不存在的路径会弹
//    Finder「找不到该文件」对话框，存在的目标则会真的拉起应用）——
//    派发契约经 dispatchToMain 测试，打开语义经注入 stub 测试。

enum AppOpener {
    /// 异步打开 URL（应用、文档、文件夹、网页、自定义 scheme 均可）。
    ///
    /// 可在任意线程调用；非主线程调用时仅做一次主线程派发（NSWorkspace 约定在主线程使用）。
    /// - Parameters:
    ///   - url: 目标 URL。
    ///   - completion: 打开结束回调（error == nil 表示成功）。系统在私有队列回调，
    ///     如需触碰 UI 请自行切回主线程。
    /// - Returns: 请求是否已成功派发出去。注意与旧同步 API 不同：返回 true 只代表
    ///     打开请求已受理，真正的成败经 completion 上报。
    @discardableResult
    static func open(_ url: URL, completion: ((Error?) -> Void)? = nil) -> Bool {
        dispatchToMain {
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
                _, error in
                if let error {
                    print("AppOpener: failed to open \(url): \(error.localizedDescription)")
                }
                completion?(error)
            }
        }
    }

    /// 异步用指定应用打开一组 URL（如用指定浏览器打开书签）。
    ///
    /// 线程约定同 `open(_:completion:)`。
    @discardableResult
    static func open(
        _ urls: [URL],
        withApplicationAt applicationURL: URL,
        completion: ((Error?) -> Void)? = nil
    ) -> Bool {
        dispatchToMain {
            NSWorkspace.shared.open(
                urls,
                withApplicationAt: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    print(
                        "AppOpener: failed to open \(urls) with \(applicationURL.path): \(error.localizedDescription)"
                    )
                }
                completion?(error)
            }
        }
    }

    /// 把打开请求派发到主线程并【立即返回】（internal 便于单元测试覆盖派发契约）。
    ///
    /// - 主线程调用：同步执行 request（本就在主线程，NSWorkspace 异步 API 自身立即返回，
    ///   不产生额外跳转开销）。
    /// - 非主线程调用：仅做一次主线程派发，不等执行完成。
    /// 「绝不阻塞」的关键由上层使用 completionHandler 版 NSWorkspace API + 源码守卫共同保证。
    @discardableResult
    static func dispatchToMain(_ request: @escaping () -> Void) -> Bool {
        if Thread.isMainThread {
            request()
        } else {
            DispatchQueue.main.async(execute: request)
        }
        return true
    }
}
