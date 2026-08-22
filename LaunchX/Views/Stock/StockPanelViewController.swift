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
    /// 查询成功后代码右侧的「（股票名称）」灰字后缀：placeholder 风格装饰不占输入内容，
    /// 清空输入（退格/全删代码）即整体消失；用户一旦手动编辑立即隐藏
    var stockNameBadge: NSTextField?
    var stockNameBadgeLeadingC: NSLayoutConstraint?
    var inputHeightConstraint: NSLayoutConstraint?
    /// 历史查询下拉按钮（输入框左侧，点击弹出最近查过的股票）
    var historyButton: NSButton?

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

    // 悬浮回图按钮（滚到下方 AI 区时出现，点击滚回顶部图表）
    var backToChartButton: NSButton?
    var backButtonShown = false
    var scrollObserverToken: NSObjectProtocol?

    // MARK: - 状态

    var settings = StockSettings.load()
    /// 最近一次查询结果（供导出/分析使用）
    var bundles: [StockDataBundle] = []
    /// 是否正在进行 AI 分析（按钮在此期间退化为「滚动定位」）
    var isAnalyzing = false
    /// 最近一次分析是否失败（失败时按钮允许直接重试，而不是仅滚动定位）
    var lastAnalysisFailed = false
    /// AI 缓冲代际：每次清空 AI 区 +1。延迟写缓存时校验，防止被新查询/分析
    /// 取代的旧任务把已作废的半截内容落盘
    var aiGeneration = 0
    /// AI 输出分段缓冲（流式到达，相邻同风格段合并；正文段渲染时走 Markdown）
    var aiSegments: [(style: AIOutputStyle, text: String)] = []
    /// 流式增量渲染器（稳定前缀 + 活跃尾部；清空 AI 区时必须 reset）
    var streamRenderer: AIStreamRenderer?
    /// 流式渲染节流任务（120ms 内多个 chunk 合并为一次全文重渲）
    var aiRenderTick: DispatchWorkItem?
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
        if let token = scrollObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
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
