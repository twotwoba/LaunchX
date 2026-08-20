import Foundation

// MARK: - 历史查询记录

/// 最近查询过的股票（输入区历史下拉项）
struct StockRecentQuery: Codable, Hashable, Identifiable {
    var id: String { code }
    /// 6 位代码（去重键）
    let code: String
    /// 展示名称
    let name: String
    /// 查询时间（仅备查，顺序由插入位置维护）
    let queriedAt: Date
}

/// 历史查询记录存储：独立 UserDefaults key。
/// 不放进 StockSettings——设置页持有整体快照，任意字段改动 save() 会整体覆盖，
/// 混存会丢掉面板刚写入的历史。
enum StockRecentStore {

    /// 最多保留条数
    static let limit = 20

    private static let key = "stockRecentQueries"

    static func load(defaults: UserDefaults = .standard) -> [StockRecentQuery] {
        guard let data = defaults.data(forKey: key),
            let list = try? JSONDecoder().decode([StockRecentQuery].self, from: data)
        else { return [] }
        return list
    }

    static func save(_ list: [StockRecentQuery], defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: key)
        }
    }

    /// 查询成功后记录：同代码去重并置顶，超限裁剪；返回最新列表
    @discardableResult
    static func record(
        code: String, name: String, defaults: UserDefaults = .standard
    ) -> [StockRecentQuery] {
        var list = load(defaults: defaults).filter { $0.code != code }
        list.insert(StockRecentQuery(code: code, name: name, queriedAt: Date()), at: 0)
        if list.count > limit {
            list = Array(list.prefix(limit))
        }
        save(list, defaults: defaults)
        return list
    }

    /// 删除一条记录；返回最新列表
    @discardableResult
    static func remove(
        code: String, defaults: UserDefaults = .standard
    ) -> [StockRecentQuery] {
        let list = load(defaults: defaults).filter { $0.code != code }
        save(list, defaults: defaults)
        return list
    }

    /// 清空全部记录
    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
