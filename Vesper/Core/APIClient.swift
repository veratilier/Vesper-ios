import Foundation
import Security
import UIKit

struct ServiceError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var code: String? = nil
    var conversationDeleted: Bool { statusCode == 410 && code == "conversation_deleted" }
    var errorDescription: String? { message }
}

enum CredentialStore {
    private static let service = "com.vera.vesper.native"
    static func read(account: String = "device-token") -> String {
        (try? load(account: account)) ?? ""
    }
    static func load(account: String = "device-token") throws -> String {
        #if targetEnvironment(macCatalyst)
        let response = try MacCredentialBridge.perform(.init(operation: "read", account: account))
        if response.status == errSecItemNotFound { return "" }
        guard response.status == errSecSuccess, let value = response.value else {
            throw ServiceError(message: "Could not read the saved credential from Keychain (\(response.status)).")
        }
        return value
        #else
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let d = result as? Data else {
            throw ServiceError(message: "Could not read the saved credential from Keychain (\(status)).")
        }
        return String(data: d, encoding: .utf8) ?? ""
        #endif
    }
    static func save(_ token: String, account: String = "device-token") throws {
        #if targetEnvironment(macCatalyst)
        let response = try MacCredentialBridge.perform(.init(operation: "save", account: account, value: token))
        guard response.status == errSecSuccess else {
            throw ServiceError(message: "Could not save the credential in Keychain (\(response.status)).")
        }
        #else
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(values) { _, v in v } as CFDictionary, nil) == errSecSuccess else { throw ServiceError(message: "Could not save the device token.") }
        } else if status != errSecSuccess { throw ServiceError(message: "Could not update the device token.") }
        #endif
        guard try load(account: account) == token else {
            throw ServiceError(message: "Keychain did not retain the credential. Please try saving again.")
        }
    }
    static func delete(account: String) throws {
        #if targetEnvironment(macCatalyst)
        let status = try MacCredentialBridge.perform(.init(operation: "delete", account: account)).status
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        #endif
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceError(message: "Could not remove the old music credential.")
        }
    }
}

struct APIClient {
    var baseURL: String
    var historyURL: String
    var token: String
    var stickerSession: URLSession = .shared
    var requestSession: URLSession = .shared
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
    /// The chat socket accepts inline image input, never the sticker catalog's HTTPS URL.
    /// Fetch from our own asset endpoint using the catalog ID rather than trusting a URL
    /// supplied in message metadata (which could point to an unrelated host).
    func stickerInputURL(assetID: String) async throws -> String {
        let data = try await stickerAssetData(assetID: assetID)
        guard let image = UIImage(data: data) else {
            throw ServiceError(message: "This sticker could not be loaded as an image. Nothing was sent.")
        }
        let scale = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, round(image.size.width * scale)), height: max(1, round(image.size.height * scale)))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard png.count <= 8 * 1024 * 1024 else { throw ServiceError(message: "This sticker is too large to send. Nothing was sent.") }
        return "data:image/png;base64," + png.base64EncodedString()
    }
    func stickerAssetData(assetID: String) async throws -> Data {
        guard (16...64).contains(assetID.count),
              assetID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }) else {
            throw ServiceError(message: "This sticker is unavailable. Nothing was sent.")
        }
        var request = URLRequest(url: try Self.validatedURL(baseURL, path: "/api/stickers/assets/\(assetID)"))
        request.timeoutInterval = 30
        let (data, response) = try await stickerSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("image/") == true,
              !data.isEmpty, data.count <= 16 * 1024 * 1024,
              UIImage(data: data) != nil else {
            throw ServiceError(message: "This sticker could not be loaded as an image. Nothing was sent.")
        }
        return data
    }
    func uploadFile(_ data: Data, name: String, mime: String, sticker: Bool = false, description: String = "", categoryID: String = "") async throws -> JSONValue {
        guard !token.isEmpty else { throw ServiceError(message: "Connect your device first.") }
        guard data.count <= 32 * 1024 * 1024 else { throw ServiceError(message: "Choose an image under 32 MB.") }
        let boundary = "Vesper-" + UUID().uuidString
        var request = URLRequest(url: try Self.validatedURL(baseURL, path: sticker ? "/api/stickers" : "/api/media"))
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue(token, forHTTPHeaderField: "x-vesper-device-token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let safeName = name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data)
        if sticker && !description.isEmpty {
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"description\"\r\n\r\n\(description)".utf8))
        }
        if sticker && !categoryID.isEmpty {
            body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"categoryId\"\r\n\r\n\(categoryID)".utf8))
        }
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let (result, response) = try await requestSession.upload(for: request, from: body)
        let value = try JSONDecoder().decode(JSONValue.self, from: result)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), sticker ? !value["sticker"]["assetId"].string.isEmpty : !value["key"].string.isEmpty else { throw ServiceError(message: value["error"].string.isEmpty ? "Image upload failed." : value["error"].string) }
        return value
    }
    func request(_ path: String, method: String = "GET", body: JSONValue? = nil, history: Bool = false) async throws -> JSONValue {
        guard !token.isEmpty else { throw ServiceError(message: "Connect your device in Settings first.") }
        let url = try Self.validatedURL(history ? historyURL : baseURL, path: path)
        var r = URLRequest(url: url); r.httpMethod = method
        // Recall can take several seconds across the memory and delivery databases.
        // Keep a bounded wait, but allow the measured 9-second retrieval to finish.
        r.timeoutInterval = path == "/api/memory/context" ? 20 : 30
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(history ? "Bearer \(token)" : token, forHTTPHeaderField: history ? "Authorization" : "x-vesper-device-token")
        if let body {
            r.httpBody = try JSONEncoder().encode(ChatHistoryUploadProjection.body(body, path: path, method: method, history: history))
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestSession.data(for: r)
        } catch let failure as URLError {
            switch failure.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                throw ServiceError(message: "Secure connection to \(url.host ?? "the server") failed (TLS, code \(failure.code.rawValue)). Check the server certificate and the device network/VPN. This does not confirm that any conversation was deleted.")
            default:
                throw failure
            }
        }
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard let response = response as? HTTPURLResponse else { throw ServiceError(message: "No HTTP response from the server.") }
        guard (200..<300).contains(response.statusCode) else {
            let detail = value["error"].string.isEmpty ? "The server could not complete this request." : value["error"].string
            throw ServiceError(message: "HTTP \(response.statusCode): " + detail, statusCode: response.statusCode, code: value["code"].string)
        }
        if method == "DELETE", value == .null { return .object([:]) }
        guard value != .null else { throw ServiceError(message: "The server returned an unreadable response.") }
        return value
    }
}

/// A network-only view of durable chat records. Building it never rewrites the
/// local message or the outbox entry that is awaiting a server receipt.
enum ChatHistoryUploadProjection {
    static func body(_ original: JSONValue, path: String, method: String, history: Bool) -> JSONValue {
        guard method == "POST" else { return original }
        let parts = path.split(separator: "?", maxSplits: 1)[0].split(separator: "/")
        if history, parts.count == 3, parts[0] == "conversations", parts[2] == "messages" {
            return message(original)
        }
        if !history, path == "/api/memory/messages", original["attachments"] != .null {
            var projected = original
            projected["attachments"] = .array(original["attachments"].array.map(attachment))
            return projected
        }
        return original
    }

    static func message(_ original: JSONValue) -> JSONValue {
        guard original["metadata"] != .null else { return original }
        var projected = original
        var metadata = original["metadata"]
        if !metadata["attachments"].array.isEmpty {
            metadata["attachments"] = .array(metadata["attachments"].array.map(attachment))
            // The model prompt may contain file previews and signed download links.
            // Visible user text remains in the message's separate content field.
            metadata["modelInputText"] = .null
        }
        if metadata["batchMessages"] != .null {
            metadata["batchMessages"] = .array(metadata["batchMessages"].array.map(message))
        }
        if metadata["replyTo"] != .null { metadata["replyTo"] = message(metadata["replyTo"]) }
        var execution = metadata["execution"]
        if fileEncodingOutput(execution) {
            let name = fileName(execution["command"])
            let format = (name as NSString).pathExtension.lowercased()
            let label = name.isEmpty ? "File record" : "File: " + name
            execution["output"] = .string("File bytes omitted from synced history.")
            execution["title"] = .string("File record")
            execution["command"] = .string(label)
            execution["fileEncoding"] = .object(["name": .string(name), "format": .string(format)])
            metadata["execution"] = execution
            projected["content"] = .string(label)
        }
        projected["metadata"] = metadata
        return projected
    }

    private static func attachment(_ original: JSONValue) -> JSONValue {
        var safe: JSONValue = .object([:])
        for key in ["name", "fileName", "type", "mimeType", "category", "createdAt", "uploadedAt"] {
            let value = original[key].string
            guard !value.isEmpty, value.utf8.count <= 255,
                  !value.contains("://"), !value.hasPrefix("data:"),
                  !value.contains("?"), !value.contains("#"), !value.contains("&"),
                  !value.contains("\n"), !value.contains("\r") else { continue }
            safe[key] = .string(value)
        }
        for key in ["size", "sizeBytes", "duration"] {
            if case .number(let value) = original[key], value.isFinite, value >= 0 {
                safe[key] = .number(value)
            }
        }
        // The bytes live in /api/media (R2), but history needs the small
        // reference in order to render and download the attachment again.
        // Never copy inline data URLs or Base64 into a chat record.
        if let url = URL(string: original["url"].string), url.scheme?.lowercased() == "https",
           url.host != nil, url.user == nil, url.password == nil,
           original["url"].string.utf8.count <= 4096 {
            safe["url"] = .string(url.absoluteString)
        }
        let key = original["key"].string
        if !key.isEmpty, key.utf8.count <= 512,
           !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            safe["key"] = .string(key)
        }
        return safe
    }

    private static func fileEncodingOutput(_ execution: JSONValue) -> Bool {
        guard execution["type"].string == "commandExecution",
              (execution["command"].string.isEmpty ? execution["command"].array.map(\.string).joined(separator: " ") : execution["command"].string)
                .range(of: #"(?:^|[\s|"'])base64(?:\s|$)"#, options: .regularExpression) != nil else { return false }
        // The tool can wrap a file in `base64 -w0` or stream it through `dd`.
        // Check only a bounded prefix; the rest may include a truncation notice.
        let prefix = execution["output"].string.utf8.prefix(8192)
        var encoded = 0
        for byte in prefix {
            if (65...90).contains(byte) || (97...122).contains(byte) ||
                (48...57).contains(byte) || byte == 43 || byte == 47 || byte == 61 {
                encoded += 1
            } else if byte != 10 && byte != 13 { return false }
        }
        return encoded >= 4096
    }

    private static func fileName(_ command: JSONValue) -> String {
        let scripts = command.string.isEmpty ? command.array.map(\.string) : [command.string]
        guard let script = scripts.last else { return "" }
        // Match the actual shell-wrapped commands as well as a direct base64 call.
        // Capturing a quoted argument keeps spaces in EPUB filenames intact.
        let patterns = [
            #"(?:^|[\s"'])dd\s+if=(?:'([^']+)'|"([^"]+)"|([^\s|]+))"#,
            #"(?:^|[\s"'])base64\s+(?:-[A-Za-z0-9]+\s+)*(?:'([^']+)'|"([^"]+)"|([^\s|]+))"#
        ]
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: range) else { continue }
            for index in 1..<match.numberOfRanges {
                guard let valueRange = Range(match.range(at: index), in: script) else { continue }
                let path = String(script[valueRange])
                let name = path.split(separator: "/").last.map(String.init) ?? ""
                guard !name.isEmpty, name.utf8.count <= 255,
                      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
                return name
            }
        }
        return ""
    }
}
private extension String { var withLeadingSlash: String { "/" + self } }
