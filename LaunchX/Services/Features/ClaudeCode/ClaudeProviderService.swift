import Foundation
import Combine

/// Provider 切换错误
enum ProviderSwitchError: LocalizedError {
    case providerNotFound
    case settingsWriteFailed(Error)
    case persistFailed(Error)

    var errorDescription: String? {
        switch self {
        case .providerNotFound:
            return "未找到目标 Provider"
        case .settingsWriteFailed(let error):
            return "写入配置失败：\(error.localizedDescription)"
        case .persistFailed(let error):
            return "保存数据失败：\(error.localizedDescription)"
        }
    }
}

/// Claude Code Provider 管理服务
@MainActor
final class ClaudeProviderService: ObservableObject {
    static let shared = ClaudeProviderService()

    @Published var providers: [ClaudeProvider] = []

    /// 当前激活的 Claude Code Provider
    var currentClaudeProvider: ClaudeProvider? {
        providers.first { $0.isCurrent && $0.apps.contains(.claude) }
    }

    /// 当前激活的 Codex Provider
    var currentCodexProvider: ClaudeProvider? {
        providers.first { $0.isCurrent && $0.apps.contains(.codex) }
    }

    /// 向后兼容：返回最近一个 isCurrent 的 provider
    var currentProvider: ClaudeProvider? {
        currentClaudeProvider ?? currentCodexProvider
    }

    private let store = ClaudeDataStore.shared
    private let fileManager = FileManager.default

    private init() {
        loadData()
    }

    // MARK: - 数据加载

    private func loadData() {
        providers = store.loadProviders()
    }

    private func persistData() throws {
        try store.saveProviders(providers)
    }

    // MARK: - Claude Code 配置文件路径

    private var claudeSettingsPath: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    // MARK: - CRUD

    /// 添加 Provider
    func addProvider(_ provider: ClaudeProvider) throws {
        var newProvider = provider
        newProvider.sortIndex = providers.count
        // 如果该 app target 下没有其他 provider，自动设为 current
        let sameAppProviders = providers.filter { !$0.apps.intersection(newProvider.apps).isEmpty }
        if sameAppProviders.isEmpty {
            newProvider.isCurrent = true
        }
        providers.append(newProvider)
        try persistData()
    }

    /// 从预设添加 Provider
    func addProvider(from preset: ClaudeProviderPreset, apiKey: String) throws {
        let provider = preset.createProvider(apiKey: apiKey)
        try addProvider(provider)
    }

    /// 更新 Provider
    func updateProvider(_ provider: ClaudeProvider) throws {
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[index] = provider
        if provider.isCurrent {
            if provider.apps.contains(.claude) {
                try writeClaudeSettings(provider)
            }
            if provider.apps.contains(.codex) {
                try writeCodexSettings(provider)
            }
        }
        try persistData()
    }

    /// 删除 Provider
    func deleteProvider(_ provider: ClaudeProvider) throws -> Bool {
        guard !provider.isCurrent else { return false }
        providers.removeAll { $0.id == provider.id }
        try persistData()
        return true
    }

    /// 获取所有 Provider
    func getAllProviders() -> [ClaudeProvider] {
        providers
    }

    // MARK: - 切换 Provider

    /// 切换到指定 Provider
    func switchProvider(to targetProvider: ClaudeProvider) throws {
        guard !targetProvider.isCurrent else { return }

        // 1. 保存旧 Provider 的 settingsConfig 快照（用于回滚）
        let snapshot = providers.map { $0 }

        // 2. Backfill: 读取当前 settings.json 回填到旧 Provider
        backfillCurrentProvider()

        // 3. 备份当前配置
        try store.backupClaudeSettings()

        // 4. 更新 isCurrent 标志（仅影响同一 app target 的 Provider）
        let targetApps = targetProvider.apps
        for i in providers.indices {
            if !providers[i].apps.intersection(targetApps).isEmpty {
                providers[i].isCurrent = (providers[i].id == targetProvider.id)
            }
        }

        // 5. 获取切换目标（更新后的）
        guard let activatedProvider = providers.first(where: { $0.id == targetProvider.id }) else {
            providers = snapshot
            throw ProviderSwitchError.providerNotFound
        }

        // 6. 写入新配置（可能抛出错误）
        do {
            if activatedProvider.apps.contains(.claude) {
                try writeClaudeSettings(activatedProvider)
            }
        } catch {
            // 回滚：恢复旧 Provider 数据
            providers = snapshot
            throw ProviderSwitchError.settingsWriteFailed(error)
        }

        // 7. 持久化
        do {
            try store.saveProviders(providers)
        } catch {
            // 持久化失败不影响已写入的 settings.json，但仍抛出错误
            throw ProviderSwitchError.persistFailed(error)
        }

        // 8. 同步 Codex 配置（如果 apps 包含 .codex）
        if activatedProvider.apps.contains(.codex) {
            try? writeCodexSettings(activatedProvider)
        }

        // 9. 触发 MCP 同步
        Task { @MainActor in
            try? ClaudeMcpService.shared.syncAll()
        }

        // 10. 触发 Skills 同步
        Task { @MainActor in
            ClaudeSkillService.shared.syncAllEnabled()
        }
    }

    // MARK: - 配置读写

    /// 读取 ~/.claude/settings.json
    func readClaudeSettings() -> [String: Any]? {
        guard fileManager.fileExists(atPath: claudeSettingsPath.path),
              let data = try? Data(contentsOf: claudeSettingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    /// 原子写入 ~/.claude/settings.json
    func writeClaudeSettings(_ provider: ClaudeProvider) throws {
        // 读取现有配置（保留非 env 字段）
        var existingConfig = readClaudeSettings() ?? [:]

        // 更新 env 字段
        existingConfig["env"] = provider.settingsConfig

        // 剥离内部字段
        let sanitized = sanitizeForLive(existingConfig)

        let jsonData = try JSONSerialization.data(
            withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])

        // 原子写入
        let tempPath = claudeSettingsPath.deletingLastPathComponent()
            .appendingPathComponent(".tmp_settings_\(UUID().uuidString)")
        do {
            try jsonData.write(to: tempPath, options: [])
            if fileManager.fileExists(atPath: claudeSettingsPath.path) {
                _ = try? fileManager.replaceItemAt(claudeSettingsPath, withItemAt: tempPath)
            } else {
                try fileManager.moveItem(at: tempPath, to: claudeSettingsPath)
            }
        } catch {
            try? fileManager.removeItem(at: tempPath)
            throw error
        }
    }

    /// 剥离内部字段（不应写入 Claude Code 配置的字段）
    private func sanitizeForLive(_ config: [String: Any]) -> [String: Any] {
        var result = config
        if var env = result["env"] as? [String: Any] {
            let internalKeys = ["apiFormat", "apiBaseUrl", "primaryModel", "smallFastModel",
                                "openrouterCompatMode", "DISABLE_NONESSENTIAL_TRAFFIC"]
            for key in internalKeys {
                env.removeValue(forKey: key)
            }
            result["env"] = env
        }
        return result
    }

    // MARK: - Codex 配置同步

    /// 将 Provider 配置写入 Codex 的 config.toml。
    ///
    /// 鉴权：Codex 的 `env_key` 仅接受"环境变量名"，真正取值依赖进程环境；
    /// 而 Codex 从 GUI / 非交互 shell 启动时未必 source rc，导致环境变量缺失、鉴权失败。
    /// 因此这里改为在 config.toml 内直接写 `experimental_bearer_token`，让 Key 随配置自包含生效。
    /// 官方要求 env_key / experimental_bearer_token / auth.command 三者互斥，
    /// 故写入 bearer_token 时不会同时写 env_key。
    func writeCodexSettings(_ provider: ClaudeProvider) throws {
        let config = provider.settingsConfig

        let apiKey = config["CODEX_API_KEY"] ?? config["ANTHROPIC_API_KEY"]
        let baseUrl = config["CODEX_BASE_URL"] ?? config["ANTHROPIC_BASE_URL"]
        let model = config["CODEX_MODEL"] ?? config["ANTHROPIC_MODEL"]
        let providerId = config["CODEX_PROVIDER_ID"]
            ?? provider.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "_")
        let envKey = config["CODEX_ENV_KEY"] ?? "OPENAI_API_KEY"

        // 1. 写入 config.toml
        let doc = store.readCodexConfig() ?? TomlDocument()

        let existingSections = doc.sectionsWithPrefix("model_providers.")
        for section in existingSections {
            doc.removeSection(section)
        }

        if let model {
            doc.set("model", value: model)
        }
        doc.set("model_provider", value: providerId)

        let providerSection = "model_providers.\(providerId)"
        doc.set("name", value: provider.name, in: providerSection)
        if let baseUrl {
            doc.set("base_url", value: baseUrl, in: providerSection)
        }
        doc.set("wire_api", value: "responses", in: providerSection)

        // 鉴权字段：env_key / experimental_bearer_token / auth.command 三者互斥。
        // 优先直接写 bearer token，使 Key 随 config.toml 自包含生效、不依赖 shell 环境；
        // 仅在未提供 Key 时回退到 env_key（登记变量名，由用户自行设置环境）。
        if let apiKey, !apiKey.isEmpty {
            doc.set("experimental_bearer_token", value: apiKey, in: providerSection)
        } else {
            doc.set("env_key", value: envKey, in: providerSection)
        }

        try store.ensureCodexDir()
        try store.writeCodexConfig(doc)

        // 旧版本（≤ 写 .zshrc 的版本）会在 shell 配置里留下明文 Key 的标记段，
        // 新版本已改用 bearer token，这里做一次性清理。
        try? removeCodexShellBlock()
    }

    /// 清理旧版本残留在 shell 配置文件中的 LaunchX Codex 标记段。
    /// 新版本已改用 config.toml 的 experimental_bearer_token 承载 Key，不再向
    /// .zshrc / .bashrc / .profile 写入 export；这里仅一次性移除历史遗留的标记段，
    /// 避免磁盘上残留明文 Key 或失效的环境变量。幂等，无标记段时为空操作。
    private func removeCodexShellBlock() throws {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.zshrc", home + "/.bashrc", home + "/.profile"]
        let beginMarker = "# >>> LaunchX Codex >>>"
        let endMarker = "# <<< LaunchX Codex <<<"

        for path in candidates {
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8),
                  content.contains(beginMarker), content.contains(endMarker),
                  let beginRange = content.range(of: beginMarker),
                  let endRange = content.range(of: endMarker) else {
                continue
            }
            var updated = content
            updated.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
            // 收敛因移除段而留下的连续空行
            while updated.contains("\n\n\n") {
                updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// 从已有 Codex 配置导入 Provider
    func importDefaultCodexConfig() -> ClaudeProvider? {
        let doc = store.readCodexConfig()
        let auth = store.readCodexAuth()

        guard doc != nil || auth != nil else { return nil }

        let model = doc?.getString("model")
        let modelProvider = doc?.getString("model_provider")

        // 尝试从 model_providers 段获取信息
        var providerName: String? = modelProvider
        var baseUrl: String?
        var envKey: String?

        if let doc = doc {
            let providerSections = doc.sectionsWithPrefix("model_providers.")
            // 如果有指定的 model_provider，优先导入那个
            if let mp = modelProvider {
                let targetSection = "model_providers.\(mp)"
                providerName = doc.getString("name", in: targetSection) ?? mp
                baseUrl = doc.getString("base_url", in: targetSection)
                envKey = doc.getString("env_key", in: targetSection)
            } else if let section = providerSections.first {
                let sectionId = section.replacingOccurrences(of: "model_providers.", with: "")
                providerName = doc.getString("name", in: section) ?? sectionId
                baseUrl = doc.getString("base_url", in: section)
                envKey = doc.getString("env_key", in: section)
            }
        }

        // 获取 API Key：从 auth.json 按 envKey 查找
        let resolvedEnvKey = envKey ?? "OPENAI_API_KEY"
        let apiKey = auth?[resolvedEnvKey] ?? auth?["OPENAI_API_KEY"]

        guard apiKey != nil || baseUrl != nil || model != nil else { return nil }

        var settingsConfig: [String: String] = [:]
        if let apiKey { settingsConfig["CODEX_API_KEY"] = apiKey }
        if let baseUrl { settingsConfig["CODEX_BASE_URL"] = baseUrl }
        if let model { settingsConfig["CODEX_MODEL"] = model }
        if let envKey { settingsConfig["CODEX_ENV_KEY"] = envKey }
        if let modelProvider { settingsConfig["CODEX_PROVIDER_ID"] = modelProvider }

        let defaultProvider = ClaudeProvider(
            name: providerName ?? "Codex 默认配置",
            settingsConfig: settingsConfig,
            category: .thirdParty,
            notes: "从现有 Codex 配置导入",
            isCurrent: false,
            apps: [.codex]
        )
        providers.append(defaultProvider)
        try? persistData()
        return defaultProvider
    }

    // MARK: - Backfill

    /// 回填当前 settings.json 配置到当前激活的 Provider
    func backfillCurrentProvider() {
        guard let liveSettings = readClaudeSettings(),
              let liveEnv = liveSettings["env"] as? [String: Any] else {
            return
        }

        // 将 [String: Any] 转换为 [String: String]
        let stringEnv = liveEnv.compactMapValues { value -> String? in
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
            return nil
        }

        // 仅回填 Claude 侧的当前 Provider：settings.json 是 Claude 专用配置，
        // 若命中 Codex Provider，会把其 CODEX_* 配置整体覆盖成 ANTHROPIC_*
        // （曾导致已存 Key / Base URL 丢失），故必须限定 apps 包含 .claude。
        for i in providers.indices {
            if providers[i].isCurrent, providers[i].apps.contains(.claude) {
                providers[i].settingsConfig = stringEnv
                break
            }
        }
    }

    // MARK: - 首次导入

    /// 导入已有的 Claude Code 配置为默认 Provider
    func importDefaultConfig() -> ClaudeProvider? {
        guard let liveSettings = readClaudeSettings(),
              let liveEnv = liveSettings["env"] as? [String: Any] else {
            return nil
        }

        // 检查是否已有 Provider
        if !providers.isEmpty { return nil }

        let stringEnv = liveEnv.compactMapValues { value -> String? in
            if let str = value as? String { return str }
            if let num = value as? NSNumber { return num.stringValue }
            return nil
        }

        // 只有当有实际配置时才导入
        let hasApiKey = stringEnv["ANTHROPIC_AUTH_TOKEN"] != nil || stringEnv["ANTHROPIC_API_KEY"] != nil
        let hasBaseUrl = stringEnv["ANTHROPIC_BASE_URL"] != nil

        guard hasApiKey || hasBaseUrl else { return nil }

        let defaultProvider = ClaudeProvider(
            name: "默认配置",
            settingsConfig: stringEnv,
            category: .official,
            notes: "从现有 Claude Code 配置导入",
            isCurrent: true
        )
        providers.append(defaultProvider)
        try? persistData()
        return defaultProvider
    }

    // MARK: - 备份管理

    /// 获取备份列表
    func listBackups() -> [URL] {
        store.listBackups()
    }

    /// 从备份恢复
    func restoreFromBackup(_ backupURL: URL) throws {
        guard let data = try? Data(contentsOf: backupURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            .write(to: claudeSettingsPath, options: .atomic)

        // 回填到当前 Provider
        backfillCurrentProvider()
        try? persistData()
    }
}
