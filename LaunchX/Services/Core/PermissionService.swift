import Cocoa
import Combine
import SwiftUI

class PermissionService: ObservableObject {
    static let shared = PermissionService()

    @Published var isAccessibilityGranted: Bool = false
    @Published var isFullDiskAccessGranted: Bool = false

    private var refreshTimer: Timer?
    private var isChecking = false
    /// 授权相关界面（欢迎引导页 / 设置页）当前是否可见：仅此时才轮询，
    /// 平时完全无 timer，与全部授权后的状态一致
    private var isPermissionUIVisible = false

    private init() {
        // 启动仅做一次状态刷新供 UI 显示，不轮询；轮询由授权界面出现触发
        checkAllPermissions()
    }

    /// 授权相关界面出现时调用（引导页 / 设置页）：立即检查一次，
    /// 若尚未全部授权则以 2s 轮询实时反馈授权进度（用户在系统设置里
    /// 打勾后尽快翻转状态）；全部授予后自动停表且不再重启。
    func startPeriodicCheck() {
        isPermissionUIVisible = true
        checkAllPermissions()
    }

    /// 授权相关界面关闭 / 应用退出时调用：无条件停表
    func stopPeriodicCheck() {
        isPermissionUIVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func checkAllPermissions() {
        // 防止重复检查
        guard !isChecking else { return }
        isChecking = true

        // 在后台线程统一检查所有权限，然后一次性更新 UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let accessibility = AXIsProcessTrusted()
            let fullDiskAccess = self.checkFullDiskAccessSync()

            DispatchQueue.main.async {
                // 一次性更新所有状态，避免竞争
                if self.isAccessibilityGranted != accessibility {
                    self.isAccessibilityGranted = accessibility
                }
                if self.isFullDiskAccessGranted != fullDiskAccess {
                    self.isFullDiskAccessGranted = fullDiskAccess
                }
                self.isChecking = false

                if self.allPermissionsGranted {
                    // 全部授予：停表。此后即使授权界面仍开着也不重启——
                    // 重开设置页时 startPeriodicCheck 会再做一次检查兜底
                    if self.refreshTimer != nil {
                        self.refreshTimer?.invalidate()
                        self.refreshTimer = nil
                        print("[PermissionService] All permissions granted, stopped periodic check")
                    }
                } else if self.isPermissionUIVisible {
                    // 有界面在等结果且仍有未授予项 → 挂 2s 轮询（幂等）
                    self.startRefreshTimer()
                }
            }
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkAllPermissions()
        }
    }

    /// 同步检查辅助功能权限（用于启动时快速检查）
    func checkAccessibilitySync() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Accessibility

    func requestAccessibility() {
        // 先调用系统 API 将应用添加到辅助功能列表（prompt: false 不显示弹窗）
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false
        ]
        AXIsProcessTrustedWithOptions(options)

        // 然后直接打开系统设置
        openAccessibilitySettings()

        // 延迟检查权限状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkAllPermissions()
        }
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    // MARK: - Full Disk Access

    private func checkFullDiskAccessSync() -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser

        // Check user's TCC database
        let userTCCPath = homeDir.appendingPathComponent(
            "Library/Application Support/com.apple.TCC/TCC.db")
        if (try? Data(contentsOf: userTCCPath, options: .mappedIfSafe)) != nil {
            return true
        }

        // Try system TCC
        if (try? Data(
            contentsOf: URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            options: .mappedIfSafe)) != nil
        {
            return true
        }

        return false
    }

    func requestFullDiskAccess() {
        // Full Disk Access 没有系统弹窗，直接打开设置
        openSystemSettings(pane: "Privacy_AllFiles")
    }

    // MARK: - Helper

    var allPermissionsGranted: Bool {
        return isAccessibilityGranted && isFullDiskAccessGranted
    }

    /// 检查是否有基本功能所需的权限（辅助功能）
    var hasRequiredPermissions: Bool {
        return isAccessibilityGranted
    }

    // MARK: - Helper

    private func openSystemSettings(pane: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
