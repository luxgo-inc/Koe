import Foundation
import Security

/// Keychain 保存（generic password）。Anthropic API キーのほか、
/// 任意アカウント名での保存にも対応（iOS 版の Google トークン等）。
/// kSecAttrAccessibleAfterFirstUnlock: バックグラウンド録音の停止処理中
/// （端末ロック中）でも要約 API キーへアクセスできるようにする。
public enum KeychainStore {
    private static let service = "jp.luxgo.koe"
    private static let apiKeyAccount = "anthropic-api-key"

    public static func saveAPIKey(_ key: String) {
        save(key, account: apiKeyAccount)
    }

    public static func loadAPIKey() -> String? {
        load(account: apiKeyAccount)
    }

    public static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
