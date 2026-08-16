import AppKit
import Foundation

/// 股票面板管理器（仿 AITranslatePanelManager）
class StockPanelManager: NSObject, NSWindowDelegate {
    static let shared = StockPanelManager()

    private var panel: StockPanel?
    private var viewController: StockPanelViewController?
    private(set) var isPanelVisible: Bool = false
    private var isPinned: Bool = false
    private var previousApp: NSRunningApplication?

    private override init() {
        super.init()
    }

    // MARK: - 面板控制

    /// 显示面板
    func showPanel() {
        if let frontApp = NSWorkspace.shared.frontmostApplication,
            frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            previousApp = frontApp
        }

        if panel == nil {
            setupPanel()
        }
        guard let panel = panel else { return }

        viewController?.reloadSettings()

        // 套用设置面板里的尺寸（面板只创建一次，stepper 改动在此生效）
        let sizeSettings = StockSettings.load()
        let target = NSSize(width: sizeSettings.panelWidth, height: sizeSettings.panelHeight)
        if panel.frame.size != target {
            panel.setContentSize(target)
        }

        // 位置：用户拖动过则恢复记忆的位置；否则与主面板出现的位置一致
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen =
            NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let screenFrame = currentScreen?.frame ?? .zero
        let panelSize = panel.frame.size

        let origin: NSPoint
        if let saved = savedOrigin, isOriginVisible(saved, panelSize: panelSize) {
            origin = saved
        } else {
            // 与主面板 PanelManager 一致的顶部基线：screen.midY + 500/2 + 50
            let topY = screenFrame.midY + 300
            origin = NSPoint(
                x: screenFrame.midX - panelSize.width / 2,
                y: topY - panelSize.height
            )
        }
        lastAppliedOrigin = origin
        panel.setFrameOrigin(origin)

        panel.collectionBehavior = [
            .moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle,
        ]

        panel.makeKeyAndOrderFront(nil)
        isPanelVisible = true
        viewController?.focusInput()
    }

    /// 隐藏面板
    func hidePanel() {
        guard !isPinned else { return }
        forceHidePanel()
    }

    /// 强制隐藏（忽略固定状态）
    func forceHidePanel() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        panel?.orderOut(nil)
    }

    /// 切换面板显示
    func togglePanel() {
        if isPanelVisible && panel?.isKeyWindow == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// 切换固定状态
    func togglePinned() {
        isPinned.toggle()
        viewController?.updatePinnedState(isPinned)
    }

    var panelIsPinned: Bool { isPinned }

    // MARK: - 面板位置持久化

    private let originXKey = "stockPanelOriginX"
    private let originYKey = "stockPanelOriginY"

    /// 用户拖动后记住的面板位置（nil = 从未拖动过）
    private var savedOrigin: NSPoint? {
        get {
            let defaults = UserDefaults.standard
            guard
                defaults.object(forKey: originXKey) != nil,
                defaults.object(forKey: originYKey) != nil
            else { return nil }
            return NSPoint(
                x: defaults.double(forKey: originXKey),
                y: defaults.double(forKey: originYKey)
            )
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(newValue.x, forKey: originXKey)
                defaults.set(newValue.y, forKey: originYKey)
            } else {
                defaults.removeObject(forKey: originXKey)
                defaults.removeObject(forKey: originYKey)
            }
        }
    }

    /// showPanel 里程序化设置的 origin，用于区分程序化移动和用户拖动
    private var lastAppliedOrigin: NSPoint?

    /// 记住的位置在当前屏幕布局下是否仍可见（至少与某块屏幕有交集，防止换屏幕后面板丢失）
    private func isOriginVisible(_ origin: NSPoint, panelSize: NSSize) -> Bool {
        let frame = NSRect(origin: origin, size: panelSize)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    // MARK: - 面板设置

    private func setupPanel() {
        let settings = StockSettings.load()

        let contentRect = NSRect(
            x: 0, y: 0,
            width: settings.panelWidth,
            height: settings.panelHeight
        )

        panel = StockPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        guard let panel = panel else { return }

        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.minSize = NSSize(width: 520, height: 360)
        panel.maxSize = NSSize(width: 1000, height: 1000)

        viewController = StockPanelViewController()
        panel.contentViewController = viewController
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if !isPinned {
            hidePanel()
        }
    }

    func windowWillClose(_ notification: Notification) {
        isPanelVisible = false
    }

    func windowDidResize(_ notification: Notification) {
        // 持久化面板尺寸
        guard let panel = panel else { return }
        var settings = StockSettings.load()
        settings.panelWidth = panel.frame.width
        settings.panelHeight = panel.frame.height
        settings.save()
    }

    func windowDidMove(_ notification: Notification) {
        // 用户拖动后记住位置（跳过 showPanel 的程序化移动）
        guard let panel = panel, panel.frame.origin != lastAppliedOrigin else { return }
        lastAppliedOrigin = panel.frame.origin
        savedOrigin = panel.frame.origin
    }
}
