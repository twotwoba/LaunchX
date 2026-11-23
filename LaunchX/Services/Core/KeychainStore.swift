import Foundation
import Security

// MARK: - Keychain 通用封装
//
// 为什么存在:百宝箱激活码属于敏感数据,按 macOS 最佳实践必须存 Keychain
// (kSecClassGenericPassword,系统级 AES-256-GCM 加密 + 访问控制),绝不明文 JSON。
// 项目此前无任何 Keychain 代码,本文件是通用基建,后续其他敏感配置也可复用。
//
// 约定:
// 1. 单测严禁触碰真实 Keychain —— 一律注入 InMemoryKeychain(见 KeychainStoreTests);
// 2. 删除顺序由调用方保证:先删 Keychain,再改清单(见 ToolboxStore.deleteItem),
//    避免"清单已删但 Keychain 残留"的泄漏。

/// Keychain 存取协议(便于单测注入内存实现,绝不触碰真实 Keychain)
protocol KeychainStoring: Sendable {
    /// 写入/覆盖 secret(已存在则走 SecItemUpdate);返回是否成功
    nonisolated func set(_ secret: String, service: String, account: String) -> Bool
    /// 读取 secret;不存在或失败返回 nil
    nonisolated func get(service: String, account: String) -> String?
    /// 删除 secret;返回是否成功(不存在也视为成功)
    nonisolated func delete(service: String, account: String) -> Bool
}

/// 真实 Keychain 实现(kSecClassGenericPassword)
final class SecItemKeychainStore: KeychainStoring {
    nonisolated func set(_ secret: String, service: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 已存在则原位更新(覆盖写入)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            // 不存在则新增
            var addAttributes = query
            addAttributes[kSecValueData as String] = data
            addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addAttributes as CFDictionary, nil) == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    nonisolated func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 不存在(errSecItemNotFound)也视为删除成功
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// 内存实现(仅供单元测试注入,绝不触碰真实 Keychain)
final class InMemoryKeychain: KeychainStoring {
    private let lock = NSLock()
    // 可变性由 lock 严格保护,标注 nonisolated(unsafe) 消除 Sendable 前瞻告警
    nonisolated(unsafe) private var storage: [String: String] = [:]

    private func key(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }

    nonisolated func set(_ secret: String, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage[key(service, account)] = secret
        return true
    }

    nonisolated func get(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(service, account)]
    }

    nonisolated func delete(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.removeValue(forKey: key(service, account)) != nil
    }
}

/// 百宝箱激活码的 Keychain 便捷入口
enum KeychainStore {
    /// 激活码专用 service(与 app bundle id 对齐)
    static let service = "twotwoba.LaunchX.toolbox"

    /// account 取条目 UUID(条目即账户,不含敏感信息)
    static func account(for itemID: UUID) -> String {
        itemID.uuidString
    }

    /// 真实实现(不可变,运行期不替换;单测走 ToolboxStore 注入,不经过这里)
    private static let impl: KeychainStoring = SecItemKeychainStore()

    static func saveSecret(_ secret: String, for itemID: UUID) -> Bool {
        impl.set(secret, service: service, account: account(for: itemID))
    }

    static func secret(for itemID: UUID) -> String? {
        impl.get(service: service, account: account(for: itemID))
    }

    @discardableResult
    static func deleteSecret(for itemID: UUID) -> Bool {
        impl.delete(service: service, account: account(for: itemID))
    }
}
