"""Exercise the production catalog transport without touching app preferences/history."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Vesper/Core/ChatSession.swift').read_text()
protocol = source[source.index('@MainActor protocol ChatSocket:'):source.index('private final class ChatPingCompletion:')]
catalog = source[source.index('@MainActor private final class ChatDeadline<Value>'):source.index('struct ChatQuestionRequest:')]
wire = source[source.index('    static func wireMessage('):source.index('    private func rpc(')]
support = '''
struct APIClient { let baseURL: String; let historyURL: String; let token: String }
struct ServiceError: LocalizedError { let message: String; var errorDescription: String? { message } }
'''
tests = r'''
@MainActor final class Socket: ChatSocket {
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data? { nil }
    var packets: [JSONValue] = [], pending: [JSONValue] = []
    var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var hang = false, fail = false
    func resume() {}
    func ping() async throws {}
    func cancel(with code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closeCode = code
        let old = waiter; waiter = nil; old?.resume(throwing: URLError(.cancelled))
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !pending.isEmpty { return try ChatSession.wireMessage(pending.removeFirst()) }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { fatalError("Expected text RPC") }
        let packet = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        packets.append(packet)
        guard packet["id"] != .null, packet["method"] != .null else { return }
        if hang { return }
        let method = packet["method"].string
        let result: JSONValue
        if method == "model/list" {
            if fail { pending.append(.object(["id": packet["id"], "error": .object(["code": .number(-1)])])); return }
            // An unsolicited notification must not swallow the response.
            pending.append(.object(["method": .string("server/notice")]))
            let next = packet["params"]["cursor"].string.isEmpty
            let names = next ? ["a", "b"] : ["b", "c"]
            result = .object(["data": .array(names.map { .object(["model": .string($0), "supportedReasoningEfforts": .array([.string("high")])]) }), "nextCursor": next ? .string("page2") : .null])
        } else { assert(method == "initialize"); result = .object([:]) }
        pending.append(.object(["id": packet["id"], "result": result]))
    }
}
@main struct Tests {
    @MainActor static func main() async throws {
        let socket = Socket()
        let models = try await ChatModelCatalog.fetch(socket: socket, timeout: 2)
        assert(models.map(\.id) == ["a", "b", "c"])
        assert(models[0]["supportedReasoningEfforts"].array.count == 1)
        assert(socket.packets.map { $0["method"].string } == ["initialize", "initialized", "model/list", "model/list"])
        assert(socket.closeCode == .normalClosure)
        let failed = Socket(); failed.fail = true
        do { _ = try await ChatModelCatalog.fetch(socket: failed, timeout: 1); fatalError("Expected server error") }
        catch { assert(failed.closeCode == .normalClosure) }
        let hung = Socket(); hung.hang = true
        let start = Date()
        do { _ = try await ChatModelCatalog.fetch(socket: hung, timeout: 0.03); fatalError("Expected deadline") }
        catch { assert((error as? URLError)?.code == .timedOut) }
        assert(Date().timeIntervalSince(start) < 1 && hung.closeCode == .normalClosure)
        let cancelled = Socket(); cancelled.hang = true
        let task = Task { try await ChatModelCatalog.fetch(socket: cancelled, timeout: 20) }
        try await Task.sleep(for: .milliseconds(10)); task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") } catch {}
        assert(cancelled.closeCode == .normalClosure)
        do {
            _ = try await ChatModelCatalog.pages { _ in .object(["data": .array([]), "nextCursor": .string("loop")]) }
            fatalError("Expected cursor loop rejection")
        } catch {}
        let api = APIClient(baseURL: "https://example.invalid", historyURL: "https://history.invalid", token: "test-only")
        let other = APIClient(baseURL: api.baseURL, historyURL: api.historyURL, token: "different")
        let key = ChatModelCatalog.cacheURL(api: api, endpoint: "wss://a.invalid")
        assert(key != ChatModelCatalog.cacheURL(api: other, endpoint: "wss://a.invalid"))
        assert(key != ChatModelCatalog.cacheURL(api: api, endpoint: "wss://b.invalid"))
        assert(!key.path.contains(api.token))
        assert(ChatModelCatalog.Cached(models: models, savedAt: Date()).fresh)
        assert(!ChatModelCatalog.Cached(models: models, savedAt: Date().addingTimeInterval(-301)).fresh)
        print("PASS: standalone catalog, pagination, descriptors, RPC errors, timeout/cancellation, cache identity and expiry; no thread/turn requests")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='vesper-model-test-') as directory:
    path = Path(directory)
    fixture = path / 'CatalogTests.swift'
    fixture.write_text('import Foundation\nimport CryptoKit\n' + protocol + support +
                       '\nenum ChatSession {\n' + wire + '}\n' + catalog + tests)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(root / 'Vesper/Core/JSONValue.swift'),
                    str(fixture), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
