import AppKit
import Foundation

/// 百宝箱通用弹窗助手(照 BackupService.showAlert 惯例:NSAlert + runModal)
/// 项目无 UserNotifications/toast 基建,完成提示统一走此入口(系统通知留作后续增强)
enum ToolboxAlerts {
    /// 任意线程调用,派发主线程弹出信息弹窗
    static func showOnMain(
        title: String, message: String, style: NSAlert.Style = .informational
    ) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                showOnMain(title: title, message: message, style: style)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    /// 主线程弹出确认弹窗;返回是否确认(第一个按钮)
    static func confirmOnMain(
        title: String, message: String, confirmTitle: String = "确认", cancelTitle: String = "取消"
    ) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                confirmOnMain(title: title, message: message, confirmTitle: confirmTitle, cancelTitle: cancelTitle)
            }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
