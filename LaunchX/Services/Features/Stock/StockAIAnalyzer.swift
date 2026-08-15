import Foundation

// MARK: - Agent 事件（B 模式 UI 进度）

enum StockAgentEvent {
    case toolStart(name: String, args: String)
    case toolDone(name: String, summary: String)
    case fallbackToQuick(String)  // 模型不支持 tools，降级提示
}

// MARK: - AI 分析器

/// 股票 AI 分析器。复用 AIModelConfig 的 OpenAI 兼容协议。
/// - A 模式（quick）：应用先取数再一次性喂给模型，单轮流式。
/// - B 模式（agent）：Function Calling 多轮，模型自主调用工具取数；不支持 tools 时自动降级 A。
final class StockAIAnalyzer {
    static let shared = StockAIAnalyzer()
    private init() {}

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    // MARK: - A 模式：快速分析

    /// bundles：已取好的数据；onDelta 收到增量文本（主线程）。
    /// onReasoning 收到推理模型的思考增量（deepseek-reasoner / v4 系列的 reasoning_content）。
    func analyzeQuick(
        bundles: [StockDataBundle], template: StockPromptTemplate, model: AIModelConfig,
        onDelta: @escaping (String) -> Void,
        onReasoning: @escaping (String) -> Void = { _ in }
    ) async throws {
        let user = buildUserMessage(template: template, bundles: bundles, includeData: true)
        let messages: [[String: Any]] = [
            ["role": "system", "content": template.systemPrompt],
            ["role": "user", "content": user],
        ]
        let (content, _) = try await streamChat(
            model: model, messages: messages, tools: nil, onDelta: onDelta, onReasoning: onReasoning)
        if content.isEmpty { onDelta("（模型未返回内容）") }
    }

    // MARK: - B 模式：深度 Agent 分析

    /// bundles 仅用于：提供 secid 清单写入提示词、以及 tools 不可用时的降级取数。
    func analyzeAgent(
        bundles: [StockDataBundle], template: StockPromptTemplate, model: AIModelConfig,
        onDelta: @escaping (String) -> Void,
        onReasoning: @escaping (String) -> Void = { _ in },
        onEvent: @escaping (StockAgentEvent) -> Void
    ) async throws {
        let user = buildUserMessage(template: template, bundles: bundles, includeData: false)
        var messages: [[String: Any]] = [
            ["role": "system", "content": template.systemPrompt + "\n\n" + Self.toolGuidance],
            ["role": "user", "content": user],
        ]
        let tools = Self.toolSchemas

        for iteration in 0..<8 {
            do {
                let (content, toolCalls) = try await streamChat(
                    model: model, messages: messages, tools: tools, onDelta: onDelta, onReasoning: onReasoning)
                if toolCalls.isEmpty {
                    if content.isEmpty { onDelta("（模型未返回内容）") }
                    return
                }
                // 追加 assistant 消息（含 tool_calls）
                messages.append(Self.assistantToolMessage(content: content, toolCalls: toolCalls))
                // 执行工具并回填
                for call in toolCalls {
                    let result = await executeTool(call)
                    emitEvent(.toolDone(name: call.name, summary: Self.shortSummary(result)), onEvent: onEvent)
                    messages.append([
                        "role": "tool", "tool_call_id": call.id, "content": result,
                    ])
                }
            } catch StockAIError.toolsNotSupported {
                // 降级到 A 模式
                emitEvent(.fallbackToQuick("当前模型不支持 Function Calling，已自动切换为快速分析"), onEvent: onEvent)
                try await analyzeQuick(bundles: bundles, template: template, model: model, onDelta: onDelta)
                return
            }
            if iteration == 7 { onDelta("\n\n（已达到工具调用次数上限）") }
        }
    }

    // MARK: - 流式 chat/completions

    private struct PendingToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    /// 发起流式请求，返回 (完整 content, 解析出的 tool_calls)
    private func streamChat(
        model: AIModelConfig, messages: [[String: Any]], tools: [[String: Any]]?,
        onDelta: @escaping (String) -> Void,
        onReasoning: @escaping (String) -> Void = { _ in }
    ) async throws -> (String, [PendingToolCall]) {
        let urlString = Self.endpointURL(baseURL: model.baseURL)
        guard let url = URL(string: urlString) else { throw StockAIError.invalidURL }

        var body: [String: Any] = [
            "model": model.model,
            "messages": messages,
            "stream": true,
            "temperature": 0.4,
        ]
        if let tools = tools { body["tools"] = tools }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch {
            throw StockAIError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw StockAIError.network("API Key 无效 (401)") }
            if !(200...299).contains(http.statusCode) {
                // 部分端点不支持 tools 时返回 400 且 body 提示；其余状态码（429/5xx…）是真实错误
                if tools != nil && http.statusCode == 400 { throw StockAIError.toolsNotSupported }
                throw StockAIError.network("HTTP \(http.statusCode)")
            }
        }

        var content = ""
        var hasReasoning = false
        var pending: [Int: PendingToolCall] = [:]
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                let obj = try? decoder.decode(StreamChunk.self, from: data),
                let delta = obj.choices.first?.delta
            else { continue }
            if let r = delta.reasoningContent, !r.isEmpty {
                if !hasReasoning {
                    hasReasoning = true
                    onReasoning("🤔 思考中：")
                }
                onReasoning(r)
            }
            if let c = delta.content, !c.isEmpty {
                if hasReasoning {
                    // 思考结束，换行后再输出正文
                    hasReasoning = false
                    onDelta("\n\n")
                }
                content += c
                onDelta(c)
            }
            if let tcs = delta.toolCalls {
                for tc in tcs {
                    var p = pending[tc.index] ?? PendingToolCall(id: "", name: "", arguments: "")
                    if let id = tc.id { p.id = id }
                    if let n = tc.function?.name { p.name = n }
                    if let a = tc.function?.arguments { p.arguments += a }
                    pending[tc.index] = p
                }
            }
        }
        let calls = pending.sorted(by: { $0.key < $1.key }).map { $0.value }.filter { !$0.name.isEmpty }
        return (content, calls)
    }

    // MARK: - 工具执行

    private func executeTool(_ call: PendingToolCall) async -> String {
        guard let argsData = call.arguments.data(using: .utf8),
            let args = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any],
            let secid = args["secid"] as? String
        else {
            return "参数错误：缺少 secid"
        }
        let days = (args["days"] as? Int) ?? 10

        switch call.name {
        case "get_realtime":
            do {
                let s = try await StockDataService.shared.fetchSnapshot(secid: secid)
                return formatSnapshot(s)
            } catch {
                return "获取实时行情失败：\(error.localizedDescription)"
            }
        case "get_history":
            do {
                let bars = try await StockDataService.shared.fetchHistory(
                    secid: secid, endYYYYMMdd: "20500101", lmt: max(5, min(days, 60)))
                return formatBars(bars.suffix(days))
            } catch {
                return "获取历史行情失败：\(error.localizedDescription)"
            }
        case "get_indicators":
            do {
                let bars = try await StockDataService.shared.fetchHistory(
                    secid: secid, endYYYYMMdd: "20500101", lmt: 130)
                let ind = StockIndicatorCalculator.compute(bars: bars)
                return formatIndicators(ind)
            } catch {
                return "获取技术指标失败：\(error.localizedDescription)"
            }
        case "get_capital_flow":
            let flows = await StockDataService.shared.fetchCapitalFlow(
                secid: secid, lmt: max(5, min(days, 30)))
            return formatFlows(flows.suffix(days))
        default:
            return "未知工具：\(call.name)"
        }
    }

    // MARK: - 消息构建

    private func buildUserMessage(
        template: StockPromptTemplate, bundles: [StockDataBundle], includeData: Bool
    ) -> String {
        let stockList = bundles.map { "\($0.name)(\($0.code))" }.joined(separator: "、")
        let dateStr = bundles.first?.targetDate ?? "最新交易日"
        var msg = template.userPromptTemplate
            .replacingOccurrences(of: "{stocks}", with: stockList)
            .replacingOccurrences(of: "{date}", with: dateStr)
        if includeData {
            msg = msg.replacingOccurrences(
                of: "{data}", with: buildContext(bundles: bundles))
        } else {
            // agent 模式：附上可用的 secid，引导模型调用工具
            let secidList = bundles.map { "- \($0.name)(\($0.code)): secid=\($0.secid)" }
                .joined(separator: "\n")
            msg = msg.replacingOccurrences(
                of: "{data}",
                with: "请通过工具函数自行获取以下股票的详细数据：\n\(secidList)")
        }
        return msg
    }

    /// A 模式：把所有 bundle 拼成结构化上下文
    func buildContext(bundles: [StockDataBundle]) -> String {
        var out = ""
        for b in bundles {
            out += "### \(b.name)(\(b.code)) 目标日期：\(b.targetDate ?? "最新")\n"
            if let s = b.snapshot { out += formatSnapshot(s) + "\n" }
            if let ind = b.indicators { out += formatIndicators(ind) + "\n" }
            if !b.capitalFlows.isEmpty {
                out += "【资金流向(近\(min(b.capitalFlows.count, 5))日)】\n"
                out += formatFlows(b.capitalFlows.suffix(5)) + "\n"
            }
            if !b.bars.isEmpty {
                out += "【近\(b.bars.count)日收盘价/涨跌幅】\n"
                out += b.bars.map { "\($0.date): 收\($0.close) 涨跌幅\($0.pctChange)% 量\($0.volume)" }
                    .joined(separator: "\n") + "\n"
            }
            if let n = b.note { out += "注：\(n)\n" }
            out += "\n"
        }
        return out
    }

    private func emitEvent(_ e: StockAgentEvent, onEvent: @escaping (StockAgentEvent) -> Void) {
        DispatchQueue.main.async { onEvent(e) }
    }

    static func endpointURL(baseURL: String) -> String {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.hasSuffix("/") { b.removeLast() }
        return "\(b)/chat/completions"
    }
}

// MARK: - AI 错误

enum StockAIError: LocalizedError {
    case invalidURL
    case network(String)
    case toolsNotSupported

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的 API 地址"
        case .network(let m): return m
        case .toolsNotSupported: return "当前模型/端点不支持 Function Calling"
        }
    }
}

// MARK: - 流式 JSON 模型

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                struct Fn: Decodable { let name: String?; let arguments: String? }
                let index: Int
                let id: String?
                let function: Fn?
            }
            let content: String?
            let reasoningContent: String?
            let toolCalls: [ToolCall]?
            enum CodingKeys: String, CodingKey {
                case content
                case reasoningContent = "reasoning_content"
                case toolCalls = "tool_calls"
            }
        }
        let delta: Delta?
    }
    let choices: [Choice]
}

// MARK: - 工具 Schema / 格式化（静态）

extension StockAIAnalyzer {

    static let toolGuidance =
        "你可以调用工具函数获取股票的实时行情、历史K线、技术指标与资金流向数据。"
        + "请根据分析需要主动调用相应工具获取充分信息后再下结论。"

    static let toolSchemas: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "get_realtime",
                "description": "获取某只 A 股的最新实时行情快照（价、量比、换手、振幅、市值、PE、PB 等）",
                "parameters": [
                    "type": "object",
                    "properties": ["secid": ["type": "string", "description": "证券ID，如 1.600519"]],
                    "required": ["secid"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "get_history",
                "description": "获取最近 N 日的日K线（开高低收/量/额/振幅/涨跌幅/换手率）",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "secid": ["type": "string"],
                        "days": ["type": "integer", "description": "天数，默认10，最大60"],
                    ] as [String: Any],
                    "required": ["secid"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "get_indicators",
                "description": "获取技术指标（MACD / KDJ / 均线 MA5/10/20/60 / 布林带）",
                "parameters": [
                    "type": "object",
                    "properties": ["secid": ["type": "string"]],
                    "required": ["secid"],
                ] as [String: Any],
            ] as [String: Any],
        ],
        [
            "type": "function",
            "function": [
                "name": "get_capital_flow",
                "description": "获取最近 N 日的资金流向（主力/超大单/大单/中单/小单净流入）",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "secid": ["type": "string"],
                        "days": ["type": "integer", "description": "天数，默认10，最大30"],
                    ] as [String: Any],
                    "required": ["secid"],
                ] as [String: Any],
            ] as [String: Any],
        ],
    ]

    private static func assistantToolMessage(content: String, toolCalls: [PendingToolCall]) -> [String: Any] {
        let calls: [[String: Any]] = toolCalls.map { c in
            [
                "id": c.id, "type": "function",
                "function": ["name": c.name, "arguments": c.arguments] as [String: Any],
            ]
        }
        return ["role": "assistant", "content": content, "tool_calls": calls]
    }

    static func shortSummary(_ s: String) -> String {
        if s.count > 40 { return String(s.prefix(40)) + "…" }
        return s
    }
}

// MARK: - 数据格式化

extension StockAIAnalyzer {

    func formatSnapshot(_ s: StockSnapshot) -> String {
        let cap = { (v: Double) -> String in
            v >= 1e8 ? String(format: "%.2f亿", v / 1e8) : String(format: "%.0f万", v / 1e4)
        }
        return """
        【实时行情 \(s.name)(\(s.code)) \(s.date)】
        最新价: \(fmt(s.price))  涨跌幅: \(fmt(s.pctChange))%  涨跌额: \(fmt(s.change))
        今开: \(fmt(s.open))  最高: \(fmt(s.high))  最低: \(fmt(s.low))  昨收: \(fmt(s.preClose))
        振幅: \(fmt(s.amplitude))%  换手率: \(fmt(s.turnover))%  量比: \(fmt(s.volumeRatio))
        总市值: \(cap(s.totalMarketCap))  流通市值: \(cap(s.circMarketCap))
        市盈率(动): \(fmt(s.pe))  市净率: \(fmt(s.pb))
        """
    }

    func formatIndicators(_ ind: StockIndicators) -> String {
        var s = "【技术指标】\n"
        if let m = ind.macd {
            s += "MACD: DIF \(fmt(m.dif)), DEA \(fmt(m.dea)), 柱 \(fmt(m.macd))\n"
        }
        if let k = ind.kdj {
            s += "KDJ: K \(fmt(k.k)), D \(fmt(k.d)), J \(fmt(k.j))\n"
        }
        s += "均线: "
        s += "MA5 \(opt(ind.ma.ma5)), MA10 \(opt(ind.ma.ma10)), MA20 \(opt(ind.ma.ma20)), MA60 \(opt(ind.ma.ma60))"
        if let u = ind.ma.bollUpper { s += "\n布林: 上\(fmt(u)) 中\(opt(ind.ma.bollMid)) 下\(opt(ind.ma.bollLower))" }
        return s
    }

    func formatBars<S: Sequence>(_ bars: S) -> String where S.Element == StockDailyBar {
        var rows = ["日期,开,收,高,低,量,涨跌幅%,换手%"]
        for b in bars {
            rows.append("\(b.date),\(fmt(b.open)),\(fmt(b.close)),\(fmt(b.high)),\(fmt(b.low)),\(b.volume),\(fmt(b.pctChange)),\(fmt(b.turnover))")
        }
        return rows.joined(separator: "\n")
    }

    func formatFlows<S: Sequence>(_ flows: S) -> String where S.Element == StockCapitalFlow {
        let cap = { (v: Double) -> String in v >= 1e8 ? String(format: "%.2f亿", v / 1e8) : String(format: "%.0f万", v / 1e4) }
        var rows = ["日期,主力,超大单,大单,中单,小单"]
        for f in flows {
            rows.append("\(f.date),\(cap(f.main)),\(cap(f.superLarge)),\(cap(f.large)),\(cap(f.medium)),\(cap(f.small))")
        }
        return rows.joined(separator: "\n")
    }

    private func fmt(_ v: Double) -> String {
        if v == 0 { return "0" }
        if abs(v) >= 1000 { return String(format: "%.2f", v) }
        return String(format: "%.2f", v)
    }
    private func opt(_ v: Double?) -> String { v.map(fmt) ?? "-" }
}
