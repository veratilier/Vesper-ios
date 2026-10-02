import XCTest
@testable import Vesper

private func usageJSON(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private final class UsageHTTPProtocol: URLProtocol {
    static var status = 200
    static var body = "{}"
    static var request: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request = request
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class UsageSocket: ChatSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data?
    var methods: [String] = []
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    func resume() {}
    func ping() async throws {}
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        receiver?.resume(throwing: CancellationError()); receiver = nil
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !inbox.isEmpty { return inbox.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        let packet = try usageJSON(text), method = packet["method"].string
        methods.append(method)
        guard packet["id"] != .null else { return }
        let response: JSONValue = method == "account/rateLimits/read"
            ? try usageJSON(#"{"rateLimits":{"secondary":{"usedPercent":37,"windowDurationMins":10080}}}"#)
            : .object([:])
        let reply: JSONValue = .object(["id": packet["id"], "result": response])
        let message = URLSessionWebSocketTask.Message.string(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        if let receiver { self.receiver = nil; receiver.resume(returning: message) }
        else { inbox.append(message) }
    }
}

@MainActor final class AccountUsageTests: XCTestCase {
    func testWeeklyQuotaUsesDurationAndPrefersNamedCodexBucket() throws {
        let value = try usageJSON(#"{"rateLimits":{"secondary":{"usedPercent":99,"windowDurationMins":10080}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":12.5,"windowDurationMins":10080,"resetsAt":1791000000},"secondary":{"usedPercent":82,"windowDurationMins":300}},"other":{"primary":{"usedPercent":98,"windowDurationMins":10080}}}}"#)
        let quota = try GPTUsageSnapshot(value)
        XCTAssertEqual(quota.usedPercent, 12.5)
        XCTAssertEqual(quota.remainingPercent, 87.5)
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 1791000000))
    }

    func testMissingWeeklyWindowOrUsedValueIsNotZero() throws {
        for json in [#"{}"#, #"{"rateLimits":{"primary":{"usedPercent":4,"windowDurationMins":300}}}"#,
                     #"{"rateLimits":{"secondary":{"windowDurationMins":10080}}}"#,
                     #"{"rateLimits":{"secondary":{"usedPercent":null,"windowDurationMins":10080}}}"#] {
            XCTAssertThrowsError(try GPTUsageSnapshot(usageJSON(json)))
        }
        let zero = try GPTUsageSnapshot(usageJSON(#"{"rateLimits":{"secondary":{"usedPercent":0,"windowDurationMins":10080}}}"#))
        XCTAssertEqual(zero.remainingPercent, 100)
        XCTAssertNil(zero.resetsAt)
    }

    func testElevenLabsRemainingResetAndOverageAreSeparate() throws {
        let quota = try ElevenLabsUsageSnapshot(usageJSON(#"{"character_count":1200,"character_limit":1000,"next_character_count_reset_unix":1791000000,"current_overage":{"amount":"1.25","currency":"usd"}}"#))
        XCTAssertEqual(quota.used, 1200)
        XCTAssertEqual(quota.remaining, 0)
        XCTAssertEqual(quota.fractionUsed, 1)
        XCTAssertEqual(quota.overageAmount, 1.25)
        XCTAssertEqual(quota.overageCurrency, "USD")
        XCTAssertEqual(quota.resetsAt, Date(timeIntervalSince1970: 1791000000))
    }

    func testElevenLabsNullAndMalformedUsageDoNotBecomeAnEmptyBalance() throws {
        for json in [#"{}"#, #"{"character_count":null,"character_limit":1000}"#,
                     #"{"character_count":3,"character_limit":null}"#,
                     #"{"character_count":-1,"character_limit":1000}"#] {
            XCTAssertThrowsError(try ElevenLabsUsageSnapshot(usageJSON(json)))
        }
        let empty = try ElevenLabsUsageSnapshot(usageJSON(#"{"character_count":0,"character_limit":0}"#))
        XCTAssertEqual(empty.remaining, 0)
        XCTAssertNil(empty.fractionUsed)
        XCTAssertNil(empty.resetsAt)
        XCTAssertNil(empty.overageAmount)
        XCTAssertNil(empty.overageCurrency)
    }

    func testProviderRequestUsesReadOnlyOfficialEndpointAndPrivateHeader() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageHTTPProtocol.self]
        UsageHTTPProtocol.status = 200
        UsageHTTPProtocol.body = #"{"character_count":350,"character_limit":1000}"#
        let quota = try await ElevenLabsUsageClient(session: URLSession(configuration: config)).fetch(apiKey: "test-provider-key")
        XCTAssertEqual(quota.remaining, 650)
        let request = try XCTUnwrap(UsageHTTPProtocol.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.elevenlabs.io/v1/user/subscription")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-provider-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-vesper-device-token"))
        XCTAssertThrowsError(try ElevenLabsUsageClient.request(apiKey: ""))
        XCTAssertThrowsError(try ElevenLabsUsageClient.request(apiKey: "key\r\nAuthorization:bad"))
    }

    func testDeniedProviderRequestDoesNotExposeResponseOrKey() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageHTTPProtocol.self]
        UsageHTTPProtocol.status = 403
        UsageHTTPProtocol.body = #"{"error":"bad key: test-secret-do-not-display"}"#
        do {
            _ = try await ElevenLabsUsageClient(session: URLSession(configuration: config)).fetch(apiKey: "test-secret-do-not-display")
            XCTFail("Expected permission error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("permission"))
            XCTAssertFalse(error.localizedDescription.contains("test-secret"))
        }
    }

    func testQuotaRefreshCannotResumeOrCreateAChat() async throws {
        let socket = UsageSocket()
        let session = ChatSession(socketFactory: { _ in socket }, heartbeatInterval: 60, requestTimeout: 1, attemptTimeout: 2)
        let quota = try await GPTUsageReader.fetch(api: APIClient(baseURL: "https://example.com", historyURL: "https://example.com", token: "test"),
            endpoint: "wss://example.com", session: session)
        XCTAssertEqual(quota.remainingPercent, 63)
        XCTAssertEqual(socket.methods, ["initialize", "initialized", "account/rateLimits/read"])
        XCTAssertNotEqual(socket.closeCode, .invalid)
    }

    func testFailedRefreshPreservesLastValueAndTimestampThenRetryReplacesIt() async {
        let state = UsageLoadState<Int>()
        await state.load(identity: "one") { 42 }
        let date = state.updatedAt
        await state.load(identity: "one") { throw UsageReadError.unavailable("Retry later") }
        XCTAssertEqual(state.value, 42)
        XCTAssertEqual(state.updatedAt, date)
        XCTAssertEqual(state.error, "Retry later")
        XCTAssertFalse(state.loading)
        await state.load(identity: "one") { 43 }
        XCTAssertEqual(state.value, 43)
        XCTAssertNil(state.error)
    }

    func testAccountChangeRejectsLateResponse() async {
        let state = UsageLoadState<Int>()
        var response: CheckedContinuation<Int, Error>?
        let old = Task { await state.load(identity: "old") { try await withCheckedThrowingContinuation { response = $0 } } }
        while response == nil { await Task.yield() }
        await state.load(identity: "new") { 9 }
        response?.resume(returning: 100)
        await old.value
        XCTAssertEqual(state.value, 9)
        XCTAssertFalse(state.loading)
        await state.load(identity: "third") { throw URLError(.cannotConnectToHost) }
        XCTAssertNil(state.value)
        XCTAssertNil(state.updatedAt)
        XCTAssertNotNil(state.error)
    }

    func testCancelledReadDoesNotLeaveSpinnerOrError() async {
        let state = UsageLoadState<Int>()
        await state.load(identity: "one") { throw CancellationError() }
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.error)
        XCTAssertNil(state.value)
    }

    func testVoiceKeyIsReusedOnlyForOfficialElevenLabs() throws {
        let voice = try usageJSON(#"{"provider":"ElevenLabs","baseUrl":"https://api.elevenlabs.io","apiKey":"test"}"#)
        XCTAssertEqual(UsageCredentials.reusableElevenLabsKey(voice), "test")
        for host in ["https://proxy.example.com", "https://api.elevenlabs.io.evil.example", "http://api.elevenlabs.io", "https://api.elevenlabs.io:1234"] {
            var custom = voice; custom["baseUrl"] = .string(host)
            XCTAssertTrue(UsageCredentials.reusableElevenLabsKey(custom).isEmpty)
        }
        var mini = voice; mini["provider"] = .string("MiniMax")
        XCTAssertTrue(UsageCredentials.reusableElevenLabsKey(mini).isEmpty)
    }

    func testCredentialedRequestsCannotFollowRedirects() {
        let url = URL(string: "https://evil.example/collect")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        var called = false
        UsageRedirectPolicy().urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: url)) { redirected in
                called = true
                XCTAssertNil(redirected)
            }
        XCTAssertTrue(called)
    }
}
