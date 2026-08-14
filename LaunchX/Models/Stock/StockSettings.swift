import Foundation

// MARK: - 分析模式

/// AI 分析模式
enum StockAnalysisMode: String, Codable, CaseIterable, Identifiable {
    /// 快速分析：应用先取数再一次性喂给模型
    case quick = "quick"
    /// 深度分析：Function Calling，模型自主调用工具取数
    case agent = "agent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: return "快速分析"
        case .agent: return "深度分析（Agent）"
        }
    }

    var iconName: String {
        switch self {
        case .quick: return "bolt.fill"
        case .agent: return "brain.head.profile"
        }
    }
}

// MARK: - 提示词模板

/// 用户自定义的分析提示词模板。
/// 占位符：{stocks}=股票清单与代码；{date}=目标日期；{data}=应用取到的结构化数据。
struct StockPromptTemplate: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var systemPrompt: String
    var userPromptTemplate: String
    /// 该模板建议使用的默认模式
    var defaultMode: StockAnalysisMode
    /// 此模板是否需要 Function Calling（仅 agent 模式生效）
    var needsTools: Bool
    var isEnabled: Bool

    init(
        id: UUID = UUID(), name: String, systemPrompt: String, userPromptTemplate: String,
        defaultMode: StockAnalysisMode = .quick, needsTools: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userPromptTemplate = userPromptTemplate
        self.defaultMode = defaultMode
        self.needsTools = needsTools
        self.isEnabled = isEnabled
    }

    /// 默认模板：多维度 T+1/T+2 研判（用户示例）
    static let defaultComprehensive = StockPromptTemplate(
        name: "多维度综合研判",
        systemPrompt:
            "你是一位严谨的 A 股投研分析师。请基于给出的数据，从基本面、技术面、资金面、筹码结构等多维度客观分析，"
            + "给出 T+1 是否值得关注、T+2 是否存在反弹/盈利可能的判断与理由。"
            + "务必给出明确结论与风险点，语气客观，不夸大。最后附上「免责声明：仅供参考，不构成投资建议」。",
        userPromptTemplate:
            "请分析以下股票在 {date}（或最新交易日）的表现：{stocks}\n\n" +
            "可用数据如下：\n{data}\n\n" +
            "请从以下维度全面分析，并给出 T+1 / T+2 的操作建议：\n" +
            "1. 结合基本面（市盈率/市净率/市值/行业）\n" +
            "2. 结合技术面（MACD/KDJ/均线/量价）\n" +
            "3. 结合资金面（主力/超大单/大单净流入）\n" +
            "4. 结合筹码密集度（如有）\n\n" +
            "结论请分点给出，最后给一句总评。",
        defaultMode: .quick
    )

    /// 默认模板：纯技术面（快速模式示例）
    static let defaultTechnical = StockPromptTemplate(
        name: "纯技术面速览",
        systemPrompt:
            "你是技术分析助手，基于 MACD、KDJ、均线、量价给出短周期技术研判。结论简短、可直接执行层面参考。",
        userPromptTemplate:
            "股票：{stocks}，日期：{date}\n数据：\n{data}\n\n请快速给出技术面多空判断与关键价位。",
        defaultMode: .quick
    )
}

// MARK: - 设置

/// 股票功能设置
struct StockSettings: Codable {
    var isEnabled: Bool
    var alias: String

    // 全局热键
    var hotKeyCode: UInt32
    var hotKeyModifiers: UInt32

    // 大模型配置（OpenAI 兼容）
    var modelConfigs: [AIModelConfig]

    // 提示词模板
    var promptTemplates: [StockPromptTemplate]

    // 面板尺寸
    var panelWidth: CGFloat
    var panelHeight: CGFloat

    static let `default` = StockSettings(
        isEnabled: true,
        alias: "gp",
        hotKeyCode: 0,
        hotKeyModifiers: 0,
        modelConfigs: [],
        promptTemplates: [.defaultComprehensive, .defaultTechnical],
        panelWidth: 720,
        panelHeight: 520
    )

    private static let storageKey = "stockSettings"

    static func load() -> StockSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(StockSettings.self, from: data)
        {
            return settings
        }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: StockSettings.storageKey)
        }
    }

    /// 默认（isDefault）模型，否则取第一个
    var defaultModel: AIModelConfig? {
        modelConfigs.first(where: { $0.isDefault }) ?? modelConfigs.first
    }
}
