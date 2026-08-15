import Carbon
import SwiftUI

/// 股票功能设置视图
struct StockSettingsView: View {
    @State private var settings = StockSettings.load()
    @State private var showHotKeyPopover = false
    @State private var showAddModelSheet = false
    @State private var editingModel: AIModelConfig?
    @State private var showAddTemplateSheet = false
    @State private var editingTemplate: StockPromptTemplate?
    /// zzshare 可选 Token（key 与 defaults write 兼容）；留空 = 匿名
    @State private var zzshareToken = UserDefaults.standard.string(forKey: "zzshare_sdk_key") ?? ""
    /// 是否明文显示 Token（默认掩码）
    @State private var showZzshareToken = false

    private let labelWidth: CGFloat = 140

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 标题头
                HStack(spacing: SettingsHeaderStyle.iconTitleSpacing) {
                    Image(systemName: AdvancedExtensionType.stock.sfSymbolName)
                        .font(.system(size: SettingsHeaderStyle.iconSize))
                        .foregroundColor(AdvancedExtensionType.stock.iconColor)
                        .frame(width: SettingsHeaderStyle.iconFrameSize, height: SettingsHeaderStyle.iconFrameSize)
                    Text("股票")
                        .font(SettingsHeaderStyle.titleFont)
                        .fontWeight(SettingsHeaderStyle.titleFontWeight)
                    Spacer()
                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: settings.isEnabled) { _, _ in settings.save() }
                }
                .padding(.horizontal, SettingsHeaderStyle.horizontalPadding)
                .padding(.top, SettingsHeaderStyle.topPadding)
                .padding(.bottom, SettingsHeaderStyle.bottomPadding)

                Divider()

                // 快捷键
                HStack {
                    Text("打开面板快捷键:")
                        .frame(width: labelWidth, alignment: .trailing)
                    ExtensionHotKeyButton(
                        keyCode: $settings.hotKeyCode,
                        modifiers: $settings.hotKeyModifiers,
                        showPopover: $showHotKeyPopover
                    )
                    .popover(isPresented: $showHotKeyPopover) {
                        ExtensionHotKeyRecorderPopover(
                            keyCode: $settings.hotKeyCode,
                            modifiers: $settings.hotKeyModifiers,
                            isPresented: $showHotKeyPopover,
                            exampleKey: "G",
                            onSave: { settings.save() },
                            onUnregister: { HotKeyService.shared.unregisterStockHotKey() },
                            onRegister: { kc, mod in
                                HotKeyService.shared.registerStockHotKey(keyCode: kc, modifiers: mod)
                            },
                            checkConflict: { kc, mod in
                                HotKeyService.shared.checkConflict(
                                    keyCode: kc, modifiers: mod, excludingMainHotKey: false)
                            }
                        )
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 别名
                HStack {
                    Text("主面板别名:")
                        .frame(width: labelWidth, alignment: .trailing)
                    TextField("gp", text: $settings.alias)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .onChange(of: settings.alias) { _, _ in settings.save() }
                    Text("输入别名回车即可打开面板")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Divider().padding(.top, 16)

                // AI 模型配置
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("AI 模型配置（OpenAI 兼容）")
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        Button(action: { showAddModelSheet = true }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }

                    if settings.modelConfigs.isEmpty {
                        emptyModelPlaceholder
                    } else {
                        ForEach(settings.modelConfigs) { config in
                            ModelConfigRow(
                                config: config,
                                isDefault: config.isDefault,
                                onEdit: { editingModel = config },
                                onDelete: { deleteModel(config) },
                                onSetDefault: { setDefaultModel(config) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider().padding(.top, 16)

                // 提示词模板
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("分析提示词模板")
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                        Button(action: { showAddTemplateSheet = true }) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                    Text("占位符：{stocks}/{ticker}=股票清单，{date}=日期，{data}=数据。快速模式把数据直接填入；深度模式（勾选 Function Calling）让 AI 自行调工具取数。")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(settings.promptTemplates) { tpl in
                        StockTemplateRow(
                            template: tpl,
                            onEdit: { editingTemplate = tpl },
                            onDelete: { deleteTemplate(tpl) },
                            onToggle: { toggleTemplate(tpl) }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider().padding(.top, 16)

                // 面板尺寸
                HStack(spacing: 16) {
                    Text("面板尺寸:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Stepper("宽 \(Int(settings.panelWidth))", value: $settings.panelWidth, in: 520...1000, step: 20)
                        .onChange(of: settings.panelWidth) { _, _ in settings.save() }
                    Stepper("高 \(Int(settings.panelHeight))", value: $settings.panelHeight, in: 360...1000, step: 20)
                        .onChange(of: settings.panelHeight) { _, _ in settings.save() }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Excel 导出列
                VStack(alignment: .leading, spacing: 8) {
                    Text("复制 Excel 导出列（每行一个交易日，不带表头）:")
                        .font(.subheadline)
                    FlowColumnPicker(columns: StockExporter.allColumns, selection: $settings.exportColumns)
                        .onChange(of: settings.exportColumns) { _, _ in settings.save() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Divider().padding(.top, 16)

                // zzshare Token（可选，默认掩码显示）
                HStack {
                    Text("zzshare Token:")
                    HStack(spacing: 4) {
                        Group {
                            if showZzshareToken {
                                TextField("留空则匿名（限频 30 次/分钟）", text: $zzshareToken)
                            } else {
                                SecureField("留空则匿名（限频 30 次/分钟）", text: $zzshareToken)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 260)
                        .onChange(of: zzshareToken) { _, _ in saveZzshareToken() }
                        Button {
                            showZzshareToken.toggle()
                        } label: {
                            Image(systemName: showZzshareToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .help(showZzshareToken ? "隐藏 Token" : "显示 Token")
                    }
                    Link("前往注册", destination: URL(string: "https://quant.zizizaizai.com/me/profile")!)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Text("（可选）免费注册后填入 token 可适当提高接口的访问频率。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                // 网络与数据源说明
                VStack(alignment: .leading, spacing: 6) {
                    Text("网络与数据源")
                        .font(.subheadline).fontWeight(.medium)
                    Text(
                        "日K/快照/搜索走腾讯，历史分时走 zzshare，失败时自动降级到新浪（部分字段缺失，卡片上会标注）。"
                            + "若查询频繁报「网络连接丢失」，常见原因与对策：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text(
                        "1. 使用代理/VPN 软件时，建议为以下域名添加直连规则（国内财经接口直连更快更稳）：\n"
                            + "DOMAIN-SUFFIX,gtimg.cn,DIRECT\n"
                            + "DOMAIN-SUFFIX,zizizaizai.com,DIRECT\n"
                            + "DOMAIN-SUFFIX,sina.cn,DIRECT\n"
                            + "DOMAIN-SUFFIX,sinajs.cn,DIRECT")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Text("2. zzshare 匿名限频 30 次/分钟，超限会自动降级到新浪分钟K（粒度变粗，几分钟后恢复）。已拉取的历史分时会缓存，重开不重复请求；填入上方免费 Token 可提高限额。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 免责
                Text("数据来源：腾讯 · 新浪 · zzshare · 仅供学习参考，不构成投资建议")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)

                Spacer()
            }
        }
        .sheet(isPresented: $showAddModelSheet) {
            ModelConfigEditorSheet(mode: .add) { newConfig in addModel(newConfig) }
        }
        .sheet(item: $editingModel) { config in
            ModelConfigEditorSheet(mode: .edit(config)) { updated in updateModel(updated) }
        }
        .sheet(isPresented: $showAddTemplateSheet) {
            StockTemplateEditorSheet(mode: .add) { newTpl in
                settings.promptTemplates.append(newTpl)
                settings.save()
            }
        }
        .sheet(item: $editingTemplate) { tpl in
            StockTemplateEditorSheet(mode: .edit(tpl)) { updated in
                if let idx = settings.promptTemplates.firstIndex(where: { $0.id == updated.id }) {
                    settings.promptTemplates[idx] = updated
                    settings.save()
                }
            }
        }
    }

    private var emptyModelPlaceholder: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "cpu").font(.title2).foregroundColor(.secondary)
                Text("暂无模型配置").font(.caption).foregroundColor(.secondary)
                Button("添加模型") { showAddModelSheet = true }.buttonStyle(.bordered)
            }
            .padding(.vertical, 20)
            Spacer()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - zzshare Token

    private func saveZzshareToken() {
        let trimmed = zzshareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "zzshare_sdk_key")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "zzshare_sdk_key")
        }
    }

    // MARK: - 模型管理

    private func addModel(_ config: AIModelConfig) {
        var c = config
        if settings.modelConfigs.isEmpty { c.isDefault = true }
        settings.modelConfigs.append(c)
        settings.save()
    }
    private func updateModel(_ config: AIModelConfig) {
        if let i = settings.modelConfigs.firstIndex(where: { $0.id == config.id }) {
            settings.modelConfigs[i] = config
            settings.save()
        }
    }
    private func deleteModel(_ config: AIModelConfig) {
        settings.modelConfigs.removeAll { $0.id == config.id }
        if config.isDefault, let first = settings.modelConfigs.first {
            settings.modelConfigs[0] = AIModelConfig(
                id: first.id, name: first.name, provider: first.provider,
                apiKey: first.apiKey, model: first.model, baseURL: first.baseURL, isDefault: true)
        }
        settings.save()
    }
    private func setDefaultModel(_ config: AIModelConfig) {
        for i in settings.modelConfigs.indices {
            settings.modelConfigs[i].isDefault = (settings.modelConfigs[i].id == config.id)
        }
        settings.save()
    }

    // MARK: - 模板管理

    private func deleteTemplate(_ tpl: StockPromptTemplate) {
        settings.promptTemplates.removeAll { $0.id == tpl.id }
        settings.save()
    }
    private func toggleTemplate(_ tpl: StockPromptTemplate) {
        if let i = settings.promptTemplates.firstIndex(where: { $0.id == tpl.id }) {
            settings.promptTemplates[i].isEnabled.toggle()
            settings.save()
        }
    }
}

// MARK: - 模板行

private struct StockTemplateRow: View {
    let template: StockPromptTemplate
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(template.name).font(.system(size: 13, weight: .medium))
                    if template.needsTools {
                        Text("需 Function Calling").font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                Text(template.userPromptTemplate.prefix(60) + (template.userPromptTemplate.count > 60 ? "…" : ""))
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onToggle) {
                Image(systemName: template.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(template.isEnabled ? .accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help(template.isEnabled ? "已启用" : "已禁用")
            Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundColor(.red)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - 模板编辑 Sheet

private struct StockTemplateEditorSheet: View {
    enum Mode {
        case add
        case edit(StockPromptTemplate)
    }

    let mode: Mode
    let onSave: (StockPromptTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var systemPrompt = ""
    @State private var userPromptTemplate = ""
    @State private var needsTools = false
    @State private var id = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if case .add = mode { Text("添加提示词模板") } else { Text("编辑提示词模板") }
            }
            .font(.headline)

            HStack {
                Text("名称:").frame(width: 80, alignment: .trailing)
                TextField("多维度综合研判", text: $name).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("系统提示词（System Prompt）")
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("用户提示词模板（支持 {stocks} {date} {data}）")
                TextEditor(text: $userPromptTemplate)
                    .font(.system(size: 12))
                    .frame(height: 110)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }

            HStack(spacing: 16) {
                Toggle("需要 Function Calling（深度分析：AI 自主调用行情工具取数）", isOn: $needsTools)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { load() }
    }

    private func load() {
        if case .edit(let tpl) = mode {
            name = tpl.name
            systemPrompt = tpl.systemPrompt
            userPromptTemplate = tpl.userPromptTemplate
            needsTools = tpl.needsTools
            id = tpl.id
        }
    }
    private func save() {
        let tpl = StockPromptTemplate(
            id: id, name: name.trimmingCharacters(in: .whitespaces),
            systemPrompt: systemPrompt, userPromptTemplate: userPromptTemplate,
            needsTools: needsTools, isEnabled: true)
        onSave(tpl)
        dismiss()
    }
}

/// 导出列勾选器（小标签流式排列，亮起=导出该列）
private struct FlowColumnPicker: View {
    let columns: [(key: String, title: String)]
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
            ForEach(columns, id: \.key) { col in
                let isOn = selection.contains(col.key)
                Button {
                    if isOn {
                        selection.removeAll { $0 == col.key }
                    } else {
                        selection.append(col.key)
                    }
                } label: {
                    Text(col.title)
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(
                            isOn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(isOn ? Color.accentColor : Color.clear, lineWidth: 1))
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
