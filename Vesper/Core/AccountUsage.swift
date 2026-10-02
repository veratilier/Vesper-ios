import Foundation
import Combine
import CryptoKit

enum UsageReadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): return message }
    }
}

private func usageNumber(_ value: JSONValue) -> Double? {
    guard case .number(let number) = value, number.isFinite, number >= 0 else { return nil }
    return number
}

struct GPTUsageSnapshot: Equatable {
    let usedPercent: Double
    let resetsAt: Date?
    var remainingPercent: Double { max(0, 100 - usedPercent) }

    init(_ response: JSONValue) throws {
        let buckets = response["rateLimitsByLimitId"]
        let limits = buckets["codex"] == .null ? response["rateLimits"] : buckets["codex"]
        guard let weekly = [limits["primary"], limits["secondary"]].first(where: {
            usageNumber($0["windowDurationMins"]) == 10_080
        }), let used = usageNumber(weekly["usedPercent"]) else {
            throw UsageReadError.unavailable("The account did not return a weekly quota. Try again later.")
        }
        usedPercent = used
        resetsAt = usageNumber(weekly["resetsAt"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }
}

struct ElevenLabsUsageSnapshot: Equatable {
    let used: Double
    let limit: Double
    let resetsAt: Date?
    let overageAmount: Double?
    let overageCurrency: String?
    var remaining: Double { max(0, limit - used) }
    var fractionUsed: Double? { limit > 0 ? min(1, used / limit) : nil }

    init(_ response: JSONValue) throws {
        guard let used = usageNumber(response["character_count"]),
              let limit = usageNumber(response["character_limit"]) else {
            throw UsageReadError.unavailable("ElevenLabs did not return usable subscription limits. Try again later.")
        }
        self.used = used; self.limit = limit
        resetsAt = usageNumber(response["next_character_count_reset_unix"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let overage = response["current_overage"]
        let amount = usageNumber(overage["amount"]) ?? Double(overage["amount"].string)
        overageAmount = amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let currency = overage["currency"].string.uppercased()
        overageCurrency = currency.count == 3 && currency.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) ? currency : nil
    }
}

/// A short, read-only connection avoids reconnecting or resuming the active chat
/// just to view account limits. No thread/start, thread/resume or turn/start.
@MainActor enum GPTUsageReader {
    static func fetch(api: APIClient, endpoint: String, session: ChatSession? = nil) async throws -> GPTUsageSnapshot {
        guard !api.token.isEmpty else { throw UsageReadError.unavailable("Connect your Vesper account in Settings first.") }
        let reader = session ?? ChatSession(requestTimeout: 10, attemptTimeout: 20)
        reader.configureConnection(api: api, endpoint: endpoint)
        defer { reader.disconnect() }
        await reader.loadUsage()
        try Task.checkCancellation()
        guard reader.usage != .null else {
            // Transport descriptions can contain the authenticated WebSocket URL.
            throw UsageReadError.unavailable("Could not read GPT quota. Check your Vesper chat connection, then retry.")
        }
        return try GPTUsageSnapshot(reader.usage)
    }
}

/// Never follow a redirect carrying a provider credential to another endpoint.
final class UsageRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ElevenLabsUsageClient {
    let session: URLSession
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config, delegate: UsageRedirectPolicy(), delegateQueue: nil)
    }
    static func request(apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw UsageReadError.unavailable("Add an ElevenLabs API key with permission to read your subscription.")
        }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func fetch(apiKey: String) async throws -> ElevenLabsUsageSnapshot {
        defer { session.finishTasksAndInvalidate() }
        let request = try Self.request(apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageReadError.unavailable("No response from ElevenLabs. Retry.") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw UsageReadError.unavailable("ElevenLabs denied access. Check the API key and its subscription read permission.")
        case 429: throw UsageReadError.unavailable("ElevenLabs is limiting requests. Wait a little, then retry.")
        default: throw UsageReadError.unavailable("ElevenLabs could not return usage (HTTP \(http.statusCode)). Retry.")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw UsageReadError.unavailable("ElevenLabs returned an unreadable response. Retry.")
        }
        return try ElevenLabsUsageSnapshot(value)
    }
}

/// Cache only in memory and only for the same account. A late response after an
/// account/key change cannot replace the new account's data or loading state.
@MainActor final class UsageLoadState<Value>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var identity: String?
    private var generation = UUID()

    func load(identity: String, operation: () async throws -> Value) async {
        if self.identity == identity, loading { return }
        if self.identity != identity {
            value = nil; updatedAt = nil; error = nil
            self.identity = identity
        }
        let current = UUID(); generation = current
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let result = try await operation()
            try Task.checkCancellation()
            guard generation == current else { return }
            value = result; updatedAt = Date()
        } catch {
            guard generation == current, !Task.isCancelled, !(error is CancellationError) else { return }
            // Do not display response bodies, URLs or provider credentials.
            self.error = (error as? UsageReadError)?.errorDescription ?? "Unable to refresh. Check your connection and retry."
        }
    }
}

@MainActor enum UsageCredentials {
    static let elevenLabsAccount = "usage-elevenlabs-api-key"
    static func fingerprint(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func elevenLabs(_ store: AppStore) -> String {
        let saved = CredentialStore.read(account: elevenLabsAccount)
        if !saved.isEmpty { return saved }
        let voice = VoiceConfiguration.connection(store)
        return reusableElevenLabsKey(voice)
    }
    static func reusableElevenLabsKey(_ voice: JSONValue) -> String {
        // A proxy key must never be sent to the official provider by guessing.
        guard voice["provider"].string.lowercased().contains("eleven"),
              let url = URLComponents(string: voice["baseUrl"].string),
              url.scheme == "https", url.host?.lowercased() == "api.elevenlabs.io",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return "" }
        return voice["apiKey"].string
    }
}
