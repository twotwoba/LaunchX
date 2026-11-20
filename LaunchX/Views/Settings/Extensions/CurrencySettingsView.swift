import SwiftUI

/// 汇率换算扩展设置页:开关 + 默认目标货币 + 使用说明
struct CurrencySettingsView: View {
    @State private var settings = CurrencySettings.load()

    private let labelWidth: CGFloat = 140

    /// 目标货币可选列表(常见币种,来自内置货币目录)
    private var targetOptions: [CurrencyDefinition] {
        let preferredCodes = ["CNY", "USD", "JPY", "EUR", "HKD", "GBP", "KRW", "TWD", "SGD", "AUD"]
        return preferredCodes.compactMap { code in
            CurrencyCatalog.currencies.first { $0.code == code }
        }
    }

    private var selectedTarget: CurrencyDefinition {
        targetOptions.first { $0.code == settings.defaultTargetCode }
            ?? CurrencyCatalog.lookup(settings.defaultTargetCode)
            ?? targetOptions[0]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 标题栏 + 总开关
                HStack(spacing: SettingsHeaderStyle.iconTitleSpacing) {
                    Image(systemName: AdvancedExtensionType.currency.sfSymbolName)
                        .font(.system(size: SettingsHeaderStyle.iconSize))
                        .foregroundColor(AdvancedExtensionType.currency.iconColor)
                        .frame(
                            width: SettingsHeaderStyle.iconFrameSize,
                            height: SettingsHeaderStyle.iconFrameSize)
                    Text("汇率换算")
                        .font(SettingsHeaderStyle.titleFont)
                        .fontWeight(SettingsHeaderStyle.titleFontWeight)
                    Spacer()

                    Toggle("", isOn: $settings.isEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: settings.isEnabled) { _, _ in
                            settings.save()
                        }
                }
                .padding(.horizontal, SettingsHeaderStyle.horizontalPadding)
                .padding(.top, SettingsHeaderStyle.topPadding)
                .padding(.bottom, SettingsHeaderStyle.bottomPadding)

                Divider()

                // 默认目标货币
                HStack {
                    Text("默认目标货币:")
                        .frame(width: labelWidth, alignment: .trailing)
                    Picker("", selection: $settings.defaultTargetCode) {
                        ForEach(targetOptions, id: \.code) { currency in
                            Text("\(currency.chineseName) (\(currency.code))")
                                .tag(currency.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .onChange(of: settings.defaultTargetCode) { _, _ in
                        settings.save()
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // 使用说明
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用说明")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    usageRow("在主搜索框直接输入金额与货币,例如:",
                        examples: ["$100", "100usd", "美元100", "100块", "100rmb"])
                    usageRow("输入 \"100usd>jpy\" 或 \"100usd to jpy\" 可指定目标货币。",
                        examples: nil)
                    usageRow("输入金额后下方会展示常用币种胶囊,点击即可切换目标货币(常用币种在前)。",
                        examples: nil)
                    usageRow("默认互转为目标货币;源币种即目标货币时,人民币与美元互相回转。",
                        examples: nil)
                    usageRow("回车复制换算结果,\"=\" 键将数值带回输入框继续计算。", examples: nil)

                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(
                            "主要币对为腾讯财经盘中实时报价,其余为 ExchangeRate-API 每日参考汇率,仅供日常参考,不构成任何投资依据。"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(20)

                Spacer()
            }
        }
    }

    /// 一行使用说明:说明文字 + 可选的示例胶囊
    private func usageRow(_ text: String, examples: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 13))
            if let examples = examples {
                HStack(spacing: 8) {
                    ForEach(examples, id: \.self) { example in
                        Text(example)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }
        }
    }
}
