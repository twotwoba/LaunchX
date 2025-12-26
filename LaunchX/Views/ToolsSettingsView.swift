import Carbon
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 网页直达编辑模式
enum WebLinkEditMode: Identifiable {
    case add
    case edit(ToolItem)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let tool): return tool.id.uuidString
        }
    }
}

// MARK: - 工具管理设置视图

struct ToolsSettingsView: View {
    @StateObject private var viewModel = ToolsViewModel()
    @State private var searchText = ""
    @State private var isDragTargeted = false
    @FocusState private var focusedField: UUID?
    @State private var webLinkEditMode: WebLinkEditMode? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部工具栏（只有搜索框）
            HStack {
                // 搜索框
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索工具...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // 列表表头
            HStack(spacing: 12) {
                Text("名称")
                    .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("别名")
                    .frame(width: 70, alignment: .leading)
                Text("快捷键")
                    .frame(width: 90, alignment: .center)
                Text("进入扩展")
                    .frame(width: 90, alignment: .center)
                Text("启用")
                    .frame(width: 44, alignment: .center)
                Spacer()
                    .frame(width: 30)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            // 列表内容
            if viewModel.tools.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 自定义应用分类
                        if !viewModel.appTools.isEmpty || !searchText.isEmpty {
                            ToolSectionHeader(
                                title: "自定义",
                                count: viewModel.appTools.count,
                                isExpanded: $viewModel.appExpanded,
                                onAdd: {
                                    viewModel.showFilePicker()
                                }
                            )

                            if viewModel.appExpanded {
                                ForEach(Array(filteredAppTools.enumerated()), id: \.element.id) {
                                    index, tool in
                                    ToolItemRow(
                                        tool: binding(for: tool),
                                        viewModel: viewModel,
                                        isEvenRow: index % 2 == 0,
                                        focusedField: $focusedField,
                                        onEdit: nil
                                    )
                                }
                            }
                        }

                        // 网页直达分类
                        ToolSectionHeader(
                            title: "网页直达",
                            count: viewModel.webLinkTools.count,
                            isExpanded: $viewModel.webLinkExpanded,
                            onAdd: {
                                webLinkEditMode = .add
                            }
                        )

                        if viewModel.webLinkExpanded {
                            if filteredWebLinkTools.isEmpty && searchText.isEmpty {
                                // 空状态提示
                                HStack {
                                    Text("点击右侧 + 添加网页直达")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .padding(.vertical, 12)
                                .padding(.horizontal, 16)
                            } else {
                                ForEach(Array(filteredWebLinkTools.enumerated()), id: \.element.id)
                                { index, tool in
                                    ToolItemRow(
                                        tool: binding(for: tool),
                                        viewModel: viewModel,
                                        isEvenRow: index % 2 == 0,
                                        focusedField: $focusedField,
                                        onEdit: {
                                            webLinkEditMode = .edit(tool)
                                        }
                                    )
                                }
                            }
                        }

                        // 实用工具分类（无添加按钮）
                        ToolSectionHeader(
                            title: "实用工具",
                            count: viewModel.utilityTools.count,
                            isExpanded: $viewModel.utilityExpanded,
                            onAdd: nil
                        )

                        if viewModel.utilityExpanded && !viewModel.utilityTools.isEmpty {
                            ForEach(Array(filteredUtilityTools.enumerated()), id: \.element.id) {
                                index, tool in
                                ToolItemRow(
                                    tool: binding(for: tool),
                                    viewModel: viewModel,
                                    isEvenRow: index % 2 == 0,
                                    focusedField: $focusedField,
                                    onEdit: nil
                                )
                            }
                        }

                        // 系统命令分类（无添加按钮）
                        ToolSectionHeader(
                            title: "系统命令",
                            count: viewModel.systemCommandTools.count,
                            isExpanded: $viewModel.systemCommandExpanded,
                            onAdd: nil
                        )

                        if viewModel.systemCommandExpanded && !viewModel.systemCommandTools.isEmpty
                        {
                            ForEach(
                                Array(filteredSystemCommandTools.enumerated()), id: \.element.id
                            ) { index, tool in
                                ToolItemRow(
                                    tool: binding(for: tool),
                                    viewModel: viewModel,
                                    isEvenRow: index % 2 == 0,
                                    focusedField: $focusedField,
                                    onEdit: nil
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                focusedField = nil
            }
        )
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            viewModel.handleDrop(providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDragTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(4)
        )
        .sheet(item: $webLinkEditMode) { mode in
            switch mode {
            case .add:
                WebLinkEditorSheet(
                    isPresented: Binding(
                        get: { webLinkEditMode != nil },
                        set: { if !$0 { webLinkEditMode = nil } }
                    ),
                    existingTool: nil,
                    onSave: { tool in
                        viewModel.addTool(tool)
                    }
                )
            case .edit(let tool):
                WebLinkEditorSheet(
                    isPresented: Binding(
                        get: { webLinkEditMode != nil },
                        set: { if !$0 { webLinkEditMode = nil } }
                    ),
                    existingTool: tool,
                    onSave: { updatedTool in
                        viewModel.updateTool(updatedTool)
                    }
                )
            }
        }
    }

    // MARK: - 辅助视图

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "plus.square.dashed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("拖拽应用或文件夹到此处")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("或点击右上角 + 按钮添加")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button("添加应用") {
                    viewModel.showFilePicker()
                }
                .buttonStyle(.borderedProminent)

                Button("添加网页") {
                    webLinkEditMode = .add
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 过滤方法

    private func filterTools(_ tools: [ToolItem]) -> [ToolItem] {
        if searchText.isEmpty { return tools }
        let lowercased = searchText.lowercased()
        return tools.filter { tool in
            tool.name.lowercased().contains(lowercased)
                || (tool.alias?.lowercased().contains(lowercased) ?? false)
                || (tool.path?.lowercased().contains(lowercased) ?? false)
                || (tool.url?.lowercased().contains(lowercased) ?? false)
        }
    }

    private var filteredAppTools: [ToolItem] {
        filterTools(viewModel.appTools)
    }

    private var filteredWebLinkTools: [ToolItem] {
        filterTools(viewModel.webLinkTools)
    }

    private var filteredUtilityTools: [ToolItem] {
        filterTools(viewModel.utilityTools)
    }

    private var filteredSystemCommandTools: [ToolItem] {
        filterTools(viewModel.systemCommandTools)
    }

    private func binding(for tool: ToolItem) -> Binding<ToolItem> {
        Binding(
            get: {
                viewModel.tools.first { $0.id == tool.id } ?? tool
            },
            set: { newValue in
                viewModel.updateTool(newValue)
            }
        )
    }
}

// MARK: - 分类标题组件

struct ToolSectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var onAdd: (() -> Void)?  // 可选的添加按钮回调

    var body: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("(\(count))")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // 添加按钮（仅当 onAdd 不为 nil 时显示）
            if let onAdd = onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("添加")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
}

// MARK: - 工具行组件

struct ToolItemRow: View {
    @Binding var tool: ToolItem
    @ObservedObject var viewModel: ToolsViewModel
    let isEvenRow: Bool
    var focusedField: FocusState<UUID?>.Binding
    var onEdit: (() -> Void)?

    @State private var aliasText: String = ""
    @State private var showHotKeyPopover = false
    @State private var showExtensionHotKeyPopover = false

    var body: some View {
        HStack(spacing: 12) {
            // 图标和名称
            HStack(spacing: 8) {
                Image(nsImage: tool.icon)
                    .resizable()
                    .frame(width: 20, height: 20)

                if tool.type == .webLink, let onEdit = onEdit {
                    // 网页直达：点击名称可编辑
                    Button(action: onEdit) {
                        Text(tool.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("点击编辑")
                } else {
                    Text(tool.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            // 别名输入
            ToolAliasTextField(
                text: $aliasText,
                placeholder: "别名",
                toolId: tool.id,
                focusedField: focusedField
            )
            .frame(width: 70)
            .onAppear {
                aliasText = tool.alias ?? ""
            }
            .onChange(of: tool.alias) { _, newValue in
                // 当 tool.alias 被外部更新时（如编辑弹窗），同步更新本地状态
                let newAlias = newValue ?? ""
                if aliasText != newAlias {
                    aliasText = newAlias
                }
            }
            .onChange(of: aliasText) { _, newValue in
                var updatedTool = tool
                updatedTool.alias = newValue.isEmpty ? nil : newValue
                viewModel.updateTool(updatedTool)
            }

            // 快捷键
            ToolHotKeyButton(
                hotKey: tool.hotKey,
                onTap: { showHotKeyPopover = true }
            )
            .frame(width: 90)
            .popover(isPresented: $showHotKeyPopover) {
                ToolHotKeyRecorderPopover(
                    hotKey: Binding(
                        get: { tool.hotKey },
                        set: { newValue in
                            tool.hotKey = newValue
                            viewModel.updateTool(tool)
                        }
                    ),
                    toolId: tool.id,
                    isExtensionHotKey: false,
                    isPresented: $showHotKeyPopover
                )
            }

            // 进入扩展快捷键（仅 IDE 显示）
            if tool.isIDE {
                ToolHotKeyButton(
                    hotKey: tool.extensionHotKey,
                    onTap: { showExtensionHotKeyPopover = true }
                )
                .frame(width: 90)
                .popover(isPresented: $showExtensionHotKeyPopover) {
                    ToolHotKeyRecorderPopover(
                        hotKey: Binding(
                            get: { tool.extensionHotKey },
                            set: { newValue in
                                tool.extensionHotKey = newValue
                                viewModel.updateTool(tool)
                            }
                        ),
                        toolId: tool.id,
                        isExtensionHotKey: true,
                        isPresented: $showExtensionHotKeyPopover
                    )
                }
            } else {
                Text("-")
                    .foregroundColor(.secondary)
                    .frame(width: 90)
            }

            // 启用开关
            Toggle(
                "",
                isOn: Binding(
                    get: { tool.isEnabled },
                    set: { newValue in
                        var updatedTool = tool
                        updatedTool.isEnabled = newValue
                        viewModel.updateTool(updatedTool)
                    }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: .accentColor))
            .scaleEffect(0.7)
            .frame(width: 44)

            // 删除按钮
            Button(action: { viewModel.deleteTool(tool) }) {
                Image(systemName: "trash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 30)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(isEvenRow ? Color.clear : Color(nsColor: .controlBackgroundColor).opacity(0.3))
        .contentShape(Rectangle())
    }
}

// MARK: - 别名输入框

struct ToolAliasTextField: View {
    @Binding var text: String
    let placeholder: String
    let toolId: UUID
    var focusedField: FocusState<UUID?>.Binding

    @State private var isHovered = false

    private var isFocused: Bool {
        focusedField.wrappedValue == toolId
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .focused(focusedField, equals: toolId)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        (isHovered || isFocused) ? Color.secondary.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - 快捷键按钮

struct ToolHotKeyButton: View {
    let hotKey: HotKeyConfig?
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            Group {
                if let hotKey = hotKey {
                    HStack(spacing: 2) {
                        ForEach(HotKeyService.modifierSymbols(for: hotKey.modifiers), id: \.self) {
                            symbol in
                            ToolKeyCapView(text: symbol)
                        }
                        ToolKeyCapView(text: HotKeyService.keyString(for: hotKey.keyCode))
                    }
                } else {
                    Text("快捷键")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        (isHovered && hotKey == nil) ? Color.secondary.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - 按键帽视图

struct ToolKeyCapView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(3)
    }
}

// MARK: - 快捷键录制弹窗

struct ToolHotKeyRecorderPopover: View {
    @Binding var hotKey: HotKeyConfig?
    let toolId: UUID
    let isExtensionHotKey: Bool
    @Binding var isPresented: Bool

    @State private var conflictMessage: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 12) {
            // 示例提示
            HStack(spacing: 4) {
                Text("例子")
                    .foregroundColor(.secondary)
                KeyCapViewLarge(text: "⌘")
                KeyCapViewLarge(text: "⇧")
                KeyCapViewLarge(text: "K")
            }
            .padding(.top, 8)

            // 提示文字或冲突信息
            if let conflict = conflictMessage {
                Text("快捷键已被「\(conflict)」使用")
                    .foregroundColor(.red)
                    .font(.system(size: 13))
            } else {
                Text("请输入快捷键...")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            // 已设置快捷键时显示
            if let currentHotKey = hotKey {
                HStack(spacing: 4) {
                    ForEach(HotKeyService.modifierSymbols(for: currentHotKey.modifiers), id: \.self)
                    { symbol in
                        KeyCapViewLarge(text: symbol)
                    }
                    KeyCapViewLarge(text: HotKeyService.keyString(for: currentHotKey.keyCode))

                    // 删除按钮
                    Button {
                        hotKey = nil
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: 280)
        .onAppear {
            HotKeyService.shared.suspendAllHotKeys()
            startRecording()
        }
        .onDisappear {
            stopRecording()
            HotKeyService.shared.resumeAllHotKeys()
        }
    }

    private func startRecording() {
        conflictMessage = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape 取消
            if event.keyCode == kVK_Escape {
                self.stopRecording()
                self.isPresented = false
                return nil
            }

            // Delete 清除
            if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
                self.hotKey = nil
                self.stopRecording()
                self.isPresented = false
                return nil
            }

            // 必须有修饰键
            let modifiers = HotKeyService.carbonModifiers(from: event.modifierFlags)
            guard modifiers != 0 else {
                return event
            }

            let keyCode = UInt32(event.keyCode)

            // 检查冲突
            if let conflict = HotKeyService.shared.checkConflict(
                keyCode: keyCode,
                modifiers: modifiers,
                excludingItemId: self.toolId,
                excludingIsExtension: self.isExtensionHotKey
            ) {
                self.conflictMessage = conflict
                return nil
            }

            // 设置快捷键
            self.hotKey = HotKeyConfig(keyCode: keyCode, modifiers: modifiers)
            self.stopRecording()
            self.isPresented = false
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - 网页直达编辑弹窗

struct WebLinkEditorSheet: View {
    @Binding var isPresented: Bool
    var existingTool: ToolItem?
    var onSave: (ToolItem) -> Void

    @State private var name: String = ""
    @State private var url: String = ""
    @State private var alias: String = ""
    @State private var urlError: String?
    @State private var iconData: Data?
    @State private var iconError: String?

    private var isEditing: Bool {
        existingTool != nil
    }

    private var isValid: Bool {
        !name.isEmpty && !url.isEmpty && isValidURL(url)
    }

    /// 当前显示的图标
    private var displayIcon: NSImage {
        if let data = iconData, let image = NSImage(data: data) {
            image.size = NSSize(width: 48, height: 48)
            return image
        }
        let defaultIcon =
            NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        defaultIcon.size = NSSize(width: 48, height: 48)
        return defaultIcon
    }

    var body: some View {
        VStack(spacing: 20) {
            // 标题
            Text(isEditing ? "编辑网页直达" : "添加网页直达")
                .font(.title3)
                .fontWeight(.semibold)

            // 图标和基本信息
            HStack(alignment: .top, spacing: 20) {
                // 图标选择区域
                VStack(spacing: 8) {
                    // 图标预览
                    Button(action: selectIcon) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .frame(width: 80, height: 80)

                            Image(nsImage: displayIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)

                            // 编辑提示
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Image(systemName: "pencil.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.accentColor)
                                        .background(
                                            Circle().fill(Color.white).frame(width: 16, height: 16))
                                }
                            }
                            .frame(width: 80, height: 80)
                            .padding(4)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("点击选择图标")

                    // 清除图标按钮
                    if iconData != nil {
                        Button("移除图标") {
                            iconData = nil
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    if let error = iconError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(width: 80)
                            .multilineTextAlignment(.center)
                    }
                }

                // 表单字段
                VStack(alignment: .leading, spacing: 14) {
                    // 名称
                    VStack(alignment: .leading, spacing: 4) {
                        Text("名称")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("例如：GitHub", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("URL")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("https://github.com", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: url) { _, newValue in
                                validateURL(newValue)
                            }
                        if let error = urlError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    // 别名
                    VStack(alignment: .leading, spacing: 4) {
                        Text("别名（可选）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("例如：gh", text: $alias)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            // 图标说明
            Text("支持 PNG、JPG 格式，建议使用 128×128 像素的正方形图片，最大 500KB")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // 按钮
            HStack {
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(isEditing ? "保存" : "添加") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if let tool = existingTool {
                name = tool.name
                url = tool.url ?? ""
                alias = tool.alias ?? ""
                iconData = tool.iconData
            }
        }
    }

    // MARK: - 图标选择

    private func selectIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "选择图标图片（PNG 或 JPG，最大 500KB）"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            loadIcon(from: url)
        }
    }

    private func loadIcon(from url: URL) {
        iconError = nil

        do {
            let data = try Data(contentsOf: url)

            // 检查文件大小（最大 500KB）
            if data.count > 500 * 1024 {
                iconError = "图片过大，请选择小于 500KB 的图片"
                return
            }

            // 验证是否为有效图片
            guard let image = NSImage(data: data) else {
                iconError = "无法读取图片"
                return
            }

            // 调整图片大小并转换为 PNG
            let resizedData = resizeAndConvertToPNG(image: image, maxSize: 128)
            iconData = resizedData

        } catch {
            iconError = "读取文件失败"
        }
    }

    /// 调整图片大小并转换为 PNG 格式
    private func resizeAndConvertToPNG(image: NSImage, maxSize: CGFloat) -> Data? {
        let originalSize = image.size

        // 计算缩放后的尺寸（保持宽高比）
        var newSize = originalSize
        if originalSize.width > maxSize || originalSize.height > maxSize {
            let ratio = min(maxSize / originalSize.width, maxSize / originalSize.height)
            newSize = NSSize(width: originalSize.width * ratio, height: originalSize.height * ratio)
        }

        // 创建新的图片
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0)
        newImage.unlockFocus()

        // 转换为 PNG 数据
        guard let tiffData = newImage.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return pngData
    }

    // MARK: - URL 验证

    private func validateURL(_ urlString: String) {
        if urlString.isEmpty {
            urlError = nil
            return
        }

        var normalizedURL = urlString
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }

        if URL(string: normalizedURL) != nil {
            urlError = nil
        } else {
            urlError = "请输入有效的 URL"
        }
    }

    private func isValidURL(_ urlString: String) -> Bool {
        var normalizedURL = urlString
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }
        return URL(string: normalizedURL) != nil
    }

    // MARK: - 保存

    private func save() {
        var normalizedURL = url
        if !normalizedURL.hasPrefix("http://") && !normalizedURL.hasPrefix("https://") {
            normalizedURL = "https://" + normalizedURL
        }

        var tool: ToolItem
        if let existing = existingTool {
            tool = existing
            tool.name = name
            tool.url = normalizedURL
            tool.alias = alias.isEmpty ? nil : alias
            tool.iconData = iconData
        } else {
            tool = ToolItem.webLink(
                name: name,
                url: normalizedURL,
                alias: alias.isEmpty ? nil : alias,
                iconData: iconData
            )
        }

        onSave(tool)
        isPresented = false
    }
}

// MARK: - ViewModel

class ToolsViewModel: ObservableObject {
    @Published var tools: [ToolItem] = []
    @Published var appExpanded: Bool = true
    @Published var webLinkExpanded: Bool = true
    @Published var utilityExpanded: Bool = false
    @Published var systemCommandExpanded: Bool = false

    init() {
        loadConfig()
    }

    // MARK: - 便捷访问

    var appTools: [ToolItem] {
        tools.filter { $0.type == .app }
    }

    var webLinkTools: [ToolItem] {
        tools.filter { $0.type == .webLink }
    }

    var utilityTools: [ToolItem] {
        tools.filter { $0.type == .utility }
    }

    var systemCommandTools: [ToolItem] {
        tools.filter { $0.type == .systemCommand }
    }

    // MARK: - 配置加载和保存

    private func loadConfig() {
        let config = ToolsConfig.load()
        tools = config.tools
    }

    private func saveConfig() {
        var config = ToolsConfig()
        config.tools = tools
        config.save()

        // 重新加载快捷键
        HotKeyService.shared.reloadToolHotKeys(from: config)
    }

    // MARK: - 工具操作

    func updateTool(_ tool: ToolItem) {
        if let index = tools.firstIndex(where: { $0.id == tool.id }) {
            tools[index] = tool
            saveConfig()
        }
    }

    func deleteTool(_ tool: ToolItem) {
        tools.removeAll { $0.id == tool.id }
        saveConfig()
    }

    func addTool(_ tool: ToolItem) {
        // 检查是否已存在
        switch tool.type {
        case .app:
            guard !tools.contains(where: { $0.type == .app && $0.path == tool.path }) else {
                return
            }
        case .webLink:
            guard !tools.contains(where: { $0.type == .webLink && $0.url == tool.url }) else {
                return
            }
        case .utility:
            guard
                !tools.contains(where: {
                    $0.type == .utility && $0.extensionIdentifier == tool.extensionIdentifier
                })
            else { return }
        case .systemCommand:
            guard
                !tools.contains(where: { $0.type == .systemCommand && $0.command == tool.command })
            else { return }
        }

        tools.append(tool)
        saveConfig()
    }

    func addApp(path: String) {
        guard !tools.contains(where: { $0.type == .app && $0.path == path }) else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        guard path.hasSuffix(".app") || isDir.boolValue else { return }

        let tool = ToolItem.app(path: path)
        tools.append(tool)
        saveConfig()
    }

    // MARK: - 拖拽处理

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                    data, _ in
                    guard let data = data as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }

                    DispatchQueue.main.async {
                        self.addApp(path: url.path)
                    }
                }
                handled = true
            }
        }

        return handled
    }

    // MARK: - 文件选择器

    func showFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application, .folder]
        panel.message = "选择要添加的应用或文件夹"
        panel.prompt = "添加"

        if panel.runModal() == .OK {
            for url in panel.urls {
                addApp(path: url.path)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ToolsSettingsView()
        .frame(width: 700, height: 450)
}
