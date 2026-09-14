import Foundation
import Security

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CredentialStore {
    private static let service = "com.vera.vesper.native"
    static func read(account: String = "device-token") -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let d = result as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, account: String = "device-token") throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(values) { _, v in v } as CFDictionary, nil) == errSecSuccess else { throw ServiceError(message: "Could not save the device token.") }
        } else if status != errSecSuccess { throw ServiceError(message: "Could not update the device token.") }
    }
}

struct APIClient {
    var baseURL: String
    var historyURL: String
    var token: String
    static func validatedURL(_ base: String, path: String) throws -> URL {
        guard let origin = URL(string: base), origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { throw ServiceError(message: "Enter a valid HTTPS server address.") }
        let relative = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        parts.path = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" + String(relative[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).withLeadingSlash + "/" + String(relative[0]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedQuery = relative.count > 1 ? String(relative[1]) : nil
        parts.fragment = nil
        guard let url = parts.url else { throw ServiceError(message: "Invalid endpoint.") }
        return url
    }
    func uploadImage(_ data: Data, name: String) async throws -> JSONValue {
        try await uploadFile(data, name: name, mime: "image/jpeg")
    }
    func uploadFile(_ data: Data, name: String, mime: String, sticker: Bool = false) async throws -> JSONValue {
        guard !token.isEmpty else { throw ServiceError(message: "Connect your device first.") }
        guard data.count <= 32 * 1024 * 1024 else { throw ServiceError(message: "Choose an image under 32 MB.") }
        let boundary = "Vesper-" + UUID().uuidString
        var request = URLRequest(url: try Self.validatedURL(baseURL, path: sticker ? "/api/stickers" : "/api/media"))
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue(token, forHTTPHeaderField: "x-vesper-device-token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (result, response) = try await URLSession.shared.upload(for: request, from: body)
        let value = try JSONDecoder().decode(JSONValue.self, from: result)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), sticker ? !value["sticker"]["assetId"].string.isEmpty : !value["key"].string.isEmpty else { throw ServiceError(message: value["error"].string.isEmpty ? "Image upload failed." : value["error"].string) }
        return value
    }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, history: Bool = false) async throws -> JSONValue {
        guard !token.isEmpty else { throw ServiceError(message: "Connect your device in Settings first.") }
        let url = try Self.validatedURL(history ? historyURL : baseURL, path: path)
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 30
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(history ? "Bearer \(token)" : token, forHTTPHeaderField: history ? "Authorization" : "x-vesper-device-token")
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: r)
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard let response = response as? HTTPURLResponse else { throw ServiceError(message: "No HTTP response from the server.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = value["error"].string.isEmpty ? "The server could not complete this request." : value["error"].string
            throw ServiceError(message: "HTTP \(response.statusCode): " + detail)
        }
        if method == "DELETE", value == .null { return .object([:]) }
        guard value != .null else { throw ServiceError(message: "The server returned an unreadable response.") }
        return value
    }
}
private extension String { var withLeadingSlash: String { "/" + self } }
