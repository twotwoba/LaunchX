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
    var pinButton: NSButton?

    // 输入区
    var inputScrollView: NSScrollView?
    var inputTextView: NSTextView?
    var inputPlaceholder: NSTextField?
    var inputHeightConstraint: NSLayoutConstraint?

    // 输入行右侧控件
    var templatePopup: NSPopUpButton?
    var analyzeButton: NSButton?

    // 内容分栏（整体放在一个纵向 NSScrollView 里：图表占满首屏，AI 分析区在其下方，
    // 点「AI 分析」滚下去、查询后滚回来；图表宽高始终保持面板可视尺寸不变）
    var contentDivider: NSView?
    var chartView: StockChartView?
    var contentScrollView: NSScrollView?
    var contentDocView: NSView?
    var aiContainerView: NSView?
    var aiScrollView: NSScrollView?
    var aiTextView: NSTextView?
    var agentEventLabel: NSTextField?  // B 模式工具进度

    var loadingIndicator: NSProgressIndicator?
    var disclaimerLabel: NSTextField?

    // MARK: - 状态

    var settings = StockSettings.load()
    /// 最近一次查询结果（供导出/分析使用）
    var bundles: [StockDataBundle] = []
    /// 是否正在进行 AI 分析（按钮在此期间退化为「滚动定位」）
    var isAnalyzing = false
    /// 最近一次分析是否失败（失败时按钮允许直接重试，而不是仅滚动定位）
    var lastAnalysisFailed = false
    /// 当前查询/分析任务（用于取消）
    var queryTask: Task<Void, Never>?
    var analyzeTask: Task<Void, Never>?

    let inputMinHeight: CGFloat = 34
    let inputMaxHeight: CGFloat = 90

    // MARK: - 生命周期

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
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

    /// 布局完成后校正输入框垂直居中：否则首启光标顶对齐（updateInputHeight 原本只在 textDidChange 触发），
    /// 面板尺寸变化时也能跟随重新居中；数值未变时内部早退，重复调用无开销
    override func viewDidLayout() {
        super.viewDidLayout()
        updateInputHeight()
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
        // 先让布局与垂直居中稳定再聚焦，避免首次打开插入点画在输入框外
        view.layoutSubtreeIfNeeded()
        updateInputHeight()
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
