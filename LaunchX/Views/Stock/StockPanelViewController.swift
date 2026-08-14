import AppKit
import Foundation

/// 股票查询 + AI 分析面板视图控制器。
/// 布局：标题栏 → 输入区 → 操作条（模式/模板/查询/复制/分析）→ 分栏（上：数据卡，下：AI 流式文本）→ 免责声明。
class StockPanelViewController: NSViewController {

    // MARK: - UI 组件（跨 extension 文件访问，故为 internal）

    var containerView: NSView?
    var visualEffectView: NSVisualEffectView?
    var glassEffectView: NSView?
    var titleBar: NSView?
    var titleLabel: NSTextField?
    var pinButton: NSButton?

    // 输入区
    var inputScrollView: NSScrollView?
    var inputTextView: NSTextView?
    var inputPlaceholder: NSTextField?
    var inputHeightConstraint: NSLayoutConstraint?

    // 操作条
    var modeSegmented: NSSegmentedControl?
    var templatePopup: NSPopUpButton?
    var queryButton: NSButton?
    var analyzeButton: NSButton?
    var copyJSONButton: NSButton?
    var copyCSVButton: NSButton?

    // 内容分栏
    var contentDivider: NSView?
    var dataScrollView: NSScrollView?
    var dataStackView: NSStackView?
    var aiScrollView: NSScrollView?
    var aiTextView: NSTextView?
    var agentEventLabel: NSTextField?  // B 模式工具进度

    var loadingIndicator: NSProgressIndicator?
    var disclaimerLabel: NSTextField?

    // MARK: - 状态

    var settings = StockSettings.load()
    /// 最近一次查询结果（供导出/分析使用）
    var bundles: [StockDataBundle] = []
    /// 当前查询/分析任务（用于取消）
    var queryTask: Task<Void, Never>?
    var analyzeTask: Task<Void, Never>?

    let inputMinHeight: CGFloat = 44
    let inputMaxHeight: CGFloat = 90

    // MARK: - 生命周期

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        applySettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLiquidGlassSettingDidChange),
            name: NSNotification.Name("enableLiquidGlassDidChange"),
            object: nil
        )
    }

    @objc func handleLiquidGlassSettingDidChange() {
        let useLiquidGlass =
            UserDefaults.standard.object(forKey: "enableLiquidGlass") as? Bool ?? true
        if #available(macOS 26.0, *) {
            glassEffectView?.isHidden = !useLiquidGlass
            visualEffectView?.isHidden = useLiquidGlass
            if !useLiquidGlass {
                visualEffectView?.material = .hudWindow
            }
        } else {
            glassEffectView?.isHidden = true
            visualEffectView?.isHidden = false
            visualEffectView?.material = .hudWindow
        }
    }

    deinit {
        queryTask?.cancel()
        analyzeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        inputTextView?.delegate = nil
    }

    // MARK: - 公开方法（供 StockPanelManager 调用）

    func reloadSettings() {
        settings = StockSettings.load()
        applySettings()
    }

    func focusInput() {
        view.window?.makeFirstResponder(inputTextView)
    }

    func updatePinnedState(_ isPinned: Bool) {
        let name = isPinned ? "pin.fill" : "pin"
        pinButton?.image = NSImage(systemSymbolName: name, accessibilityDescription: "固定")
    }

    private func applySettings() {
        rebuildTemplatePopup()
    }
}
