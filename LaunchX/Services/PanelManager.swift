import Cocoa

class PanelManager: NSObject, NSWindowDelegate {
    static let shared = PanelManager()

    private(set) var isPanelVisible: Bool = false

    // Callback to reset view state before hiding
    var onWillHide: (() -> Void)?

    private var panel: FloatingPanel!
    private var viewController: SearchPanelViewController?
    private var lastShowTime: Date = .distantPast
    private var isSetup = false

    private override init() {
        super.init()
    }

    /// Must be called once after app launches
    func setup() {
        guard !isSetup else { return }
        isSetup = true

        let panelSize = NSSize(width: 650, height: 80)
        let screenRect = NSScreen.main?.frame ?? .zero
        let centerOrigin = NSPoint(
            x: screenRect.midX - panelSize.width / 2,
            y: screenRect.midY - panelSize.height / 2 + 100)

        let rect = NSRect(origin: centerOrigin, size: panelSize)

        self.panel = FloatingPanel(contentRect: rect)
        self.panel.delegate = self

        // Setup AppKit view controller
        viewController = SearchPanelViewController()
        panel.contentView = viewController?.view
    }

    func togglePanel() {
        guard isSetup else { return }

        if panel.isVisible && NSApp.isActive {
            // 检查是否有其他窗口（如设置窗口）打开
            let hasOtherVisibleWindows = NSApp.windows.contains { window in
                window != panel && window.isVisible && !window.isKind(of: NSPanel.self)
            }
            hidePanel(deactivateApp: !hasOtherVisibleWindows)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard isSetup else { return }

        lastShowTime = Date()

        // Center on the main screen
        let screenRect = NSScreen.main?.frame ?? .zero
        let panelFrame = panel.frame
        let centerOrigin = NSPoint(
            x: screenRect.midX - panelFrame.width / 2,
            y: screenRect.midY - panelFrame.height / 2 + 100)
        panel.setFrameOrigin(centerOrigin)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        // Focus the search field
        viewController?.focus()

        isPanelVisible = true
    }

    func hidePanel(deactivateApp: Bool = false) {
        guard isSetup else { return }

        // Reset state BEFORE hiding
        onWillHide?()
        viewController?.resetState()

        panel.orderOut(nil)

        if deactivateApp {
            NSApp.hide(nil)
        }

        isPanelVisible = false
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard isSetup else { return }

        if let window = notification.object as? NSWindow, window == self.panel {
            if Date().timeIntervalSince(lastShowTime) < 0.3 {
                return
            }
            hidePanel(deactivateApp: false)
        }
    }
}
