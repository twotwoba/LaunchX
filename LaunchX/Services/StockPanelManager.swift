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

        // 鼠标所在屏幕居中、稍偏上
        let mouseLocation = NSEvent.mouseLocation
        let currentScreen =
            NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let screenFrame = currentScreen?.visibleFrame ?? .zero
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.midY + 50

        panel.setFrameOrigin(NSPoint(x: x, y: y))

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
}
