import Foundation
import Security

// Separate Keychain item shared only by the app and broadcast extension.
enum BroadcastAccess {
    static let group = "group.com.vera.vesper.native"
    static func credentials() -> (String, String)? {
        guard let endpoint = UserDefaults(suiteName: group)?.string(forKey: "broadcastEndpoint"),
              let access = Bundle.main.object(forInfoDictionaryKey: "BroadcastKeychainGroup") as? String else { return nil }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "vesper.broadcast", kSecAttrAccount as String: "token", kSecAttrAccessGroup as String: access, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return (endpoint, token)
    }
    static func save(endpoint: String, token: String) throws {
        guard let access = Bundle.main.object(forInfoDictionaryKey: "BroadcastKeychainGroup") as? String else { throw NSError(domain: "Vesper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Broadcast Keychain group is missing."]) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "vesper.broadcast", kSecAttrAccount as String: "token", kSecAttrAccessGroup as String: access]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { UserDefaults(suiteName: group)?.removeObject(forKey: "broadcastEndpoint"); return }
        let values = query.merging([kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, new in new }
        guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw NSError(domain: "Vesper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Enable shared Keychain access for the app and broadcast extension."]) }
        UserDefaults(suiteName: group)?.set(endpoint, forKey: "broadcastEndpoint")
    }
}
