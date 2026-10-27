import Foundation
import Security

// Separate Keychain item shared only by the app and broadcast extension.
enum BroadcastAccess {
    struct Configuration {
        let historyURL: String
        let token: String
        let conversationID: String
        let instructions: String
        let name: String
        let userName: String
        let model: String
    }
    static func credentials() -> Configuration? {
        guard let value = read(account: "token"), let historyURL = value["historyURL"] as? String,
              let token = value["token"] as? String, !token.isEmpty,
              let room = value["conversationId"] as? String, !room.isEmpty else { return nil }
        return Configuration(historyURL: historyURL, token: token, conversationID: room,
            instructions: value["instructions"] as? String ?? "Speak naturally in Chinese.",
            name: value["name"] as? String ?? "", userName: value["userName"] as? String ?? "",
            model: value["model"] as? String ?? "")
    }
    static func save(historyURL: String, token: String, conversationID: String, instructions: String, name: String, userName: String, model: String) throws {
        try write(account: "token", value: ["historyURL": historyURL, "token": token, "conversationId": conversationID,
            "instructions": String(instructions.prefix(16000)), "name": String(name.prefix(80)),
            "userName": String(userName.prefix(80)), "model": model])
    }
    static func observation() -> [String: Any] { read(account: "observation") ?? [:] }
    static func resetObservation() { try? write(account: "observation", value: [:]) }
    static func preferences() -> [String: Any] { read(account: "preferences") ?? [:] }
    static func captureInterval() -> TimeInterval {
        let value = preferences()["captureInterval"] as? Double ?? 10
        return [5.0, 10.0, 20.0, 30.0].contains(value) ? value : 10
    }
    static func setCaptureInterval(_ interval: TimeInterval) throws {
        guard [5.0, 10.0, 20.0, 30.0].contains(interval) else { return }
        var value = preferences()
        value["captureInterval"] = interval
        try write(account: "preferences", value: value)
    }
    static func lookRequest() -> Int { preferences()["lookRequest"] as? Int ?? 0 }
    static func requestLookNow() throws {
        var value = preferences()
        value["lookRequest"] = (value["lookRequest"] as? Int ?? 0) + 1
        try write(account: "preferences", value: value)
    }
    static func isSharing() -> Bool {
        let state = observation()
        let updatedAt = state["updatedAt"] as? Double ?? 0
        return state["sharing"] as? Bool == true && Date().timeIntervalSince1970 - updatedAt < 20
    }
    static func heartbeat() {
        var value = observation()
        guard value["sharing"] as? Bool == true else { return }
        value["updatedAt"] = Date().timeIntervalSince1970
        try? write(account: "observation", value: value)
    }
    static func updateObservation(status: String, reply: String? = nil, sharing: Bool? = nil) {
        var value = observation()
        value["status"] = status
        value["updatedAt"] = Date().timeIntervalSince1970
        if let sharing { value["sharing"] = sharing }
        if let reply, !reply.isEmpty { value["reply"] = String(reply.prefix(2000)); value["replyAt"] = Date().timeIntervalSince1970 }
        try? write(account: "observation", value: value)
    }
    private static func query(account: String) -> [String: Any]? {
        guard let access = Bundle.main.object(forInfoDictionaryKey: "BroadcastKeychainGroup") as? String else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "vesper.broadcast", kSecAttrAccount as String: account, kSecAttrAccessGroup as String: access]
    }
    private static func read(account: String) -> [String: Any]? {
        guard var query = query(account: account) else { return nil }
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func write(account: String, value: [String: Any]) throws {
        guard let query = query(account: account) else { throw NSError(domain: "Vesper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Broadcast Keychain group is missing."]) }
        let data = try JSONSerialization.data(withJSONObject: value)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw NSError(domain: "Vesper", code: Int(result), userInfo: [NSLocalizedDescriptionKey: "Unable to prepare shared screen access (\(result))."]) }
    }
}
