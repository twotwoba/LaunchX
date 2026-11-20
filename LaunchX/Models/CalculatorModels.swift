import Foundation

// MARK: - 计算器模型

/// 计算器角度制模式:三角/反三角函数按弧度或角度解释
enum CalculatorAngleMode: String, Codable {
    case radians
    case degrees
}

/// 计算器求值结果:`value` 参与后续计算(ans 变量),`copyText` 供复制/回填(无分组分隔符)
struct CalculatorResult {
    let value: Double
    let copyText: String
}

/// 计算器设置(仿 CurrencySettings 的 UserDefaults 轻量持久化)
struct CalculatorSettings: Codable {
    var angleUnit: CalculatorAngleMode

    static let `default` = CalculatorSettings(angleUnit: .radians)

    private static let storageKey = "launchx.calculatorSettings"
    private static var cached: CalculatorSettings?

    /// 读取设置(带进程内缓存,输入框每键触发,避免反复解码)
    static func load() -> CalculatorSettings {
        if let cached = cached { return cached }
        if let data = UserDefaults.standard.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(CalculatorSettings.self, from: data)
        {
            cached = settings
            return settings
        }
        cached = .default
        return .default
    }

    /// 保存设置并刷新进程内缓存
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        CalculatorSettings.cached = self
    }
}

/// 计算历史条目(持久化于 App Support/LaunchX/calculator/history.json)
struct CalculatorHistoryEntry: Codable, Equatable {
    let expression: String
    let result: String
    let recordedAt: Date
}
