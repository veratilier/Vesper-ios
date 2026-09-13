import Foundation
import SwiftUI

@MainActor final class ChatSession: ObservableObject {
    @Published var messages: [JSONValue] = []
    @Published var conversations: [JSONValue] = []
    @Published var models: [JSONValue] = []
    @Published var loadingModels = false
    @Published var modelError: String?
    @Published var usage: JSONValue = .null
    @Published var loadingUsage = false
    @Published var usageError: String?
    private var connectionTask: Task<Void, Error>?
    @Published var model = ""
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var approval: JSONValue?
    @Published var events: [String] = []
    private(set) var conversationID = UUID().uuidString
    private var threadID: String?
    private var turnID: String?
    private var api: APIClient?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var initialized = false
    private var endpoint = ""
    private let config: JSONValue = .object([
        "apps.asdk_app_6a92be9d9e1c819197f58017d0e2b985.enabled": .bool(false),
        "apps.app_6a92be9d9e1c819197f58017d0e2b985.enabled": .bool(false)
    ])
    func configure(_ store: AppStore) { api = store.api; endpoint = store.socketURL }
    func loadConversations() async {
        guard let api else { return }
        do { let r = try await api.request("/conversations", history: true); conversations = r["conversations"].array }
        catch { self.error = error.localizedDescription }
    }
    func open(_ conversation: JSONValue) async {
        guard !busy, let api else { return }
        disconnect(); conversationID = conversation.id; threadID = nil; messages = []; events = []
        do {
            let r = try await api.request("/conversations/\(conversationID)", history: true)
            let t = r["conversation"]["codexThreadId"].string
            threadID = t.isEmpty ? nil : t
            messages = r["messages"].array
            status = "History loaded"
        } catch { self.error = error.localizedDescription }
    }
    func newConversation() {
        guard !busy else { return }; disconnect(); conversationID = UUID().uuidString; threadID = nil; turnID = nil; messages = []; events = []; status = "New conversation"
    }
    func disconnect() {
        connectionTask?.cancel(); connectionTask = nil
        receiveTask?.cancel(); receiveTask = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil; initialized = false
        for (_, timer) in timeouts { timer.cancel() }; timeouts.removeAll()
        let requests = pending; pending.removeAll()
        for (_, continuation) in requests { continuation.resume(throwing: ServiceError(message: "Chat connection closed.")) }
    }
    private func sendPacket(_ packet: JSONValue) async throws {
        guard let socket else { throw ServiceError(message: "Chat is disconnected.") }
        try await socket.send(Self.wireMessage(packet))
    }
    static func wireMessage(_ packet: JSONValue) throws -> URLSessionWebSocketTask.Message {
        let data = try JSONEncoder().encode(packet)
        // Match the browser and app-server JSON-RPC text-frame transport.
        return .string(String(decoding: data, as: UTF8.self))
    }
    private func rpc(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self, let c = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id); c.resume(throwing: ServiceError(message: "Request timed out (\(method)). Check history before resending."))
            }
            Task { [weak self] in
                guard let self else { return }
                do { try await self.sendPacket(.object(["id": .string(id), "method": .string(method), "params": params])) }
                catch { self.timeouts.removeValue(forKey: id)?.cancel(); self.pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        }
    }
    func connect() async throws {
        if initialized { return }
        if let connectionTask { try await connectionTask.value; return }
        let task = Task { try await self.establishConnection() }
        connectionTask = task
        defer { connectionTask = nil }
        try await task.value
    }
    private func establishConnection() async throws {
        guard !initialized, let api else { return }
        guard !api.token.isEmpty, var u = URLComponents(string: endpoint), u.scheme == "wss", u.host != nil else { throw ServiceError(message: "Pair this device in Settings first.") }
        u.queryItems = (u.queryItems ?? []).filter { $0.name != "token" } + [URLQueryItem(name: "token", value: api.token)]
        guard let url = u.url else { throw ServiceError(message: "Invalid chat address.") }
        let ws = URLSession.shared.webSocketTask(with: url); socket = ws; ws.resume()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                    let packet = try JSONDecoder().decode(JSONValue.self, from: data)
                    await self?.handle(packet)
                }
            } catch {
                guard !Task.isCancelled, self?.socket === ws else { return }
                self?.error = "Chat connection interrupted. Reopen the conversation to check the server history before resending."
                self?.busy = false; self?.disconnect()
            }
        }
        do {
        _ = try await rpc("initialize", .object(["clientInfo": .object(["name": .string("vesper_ios"), "title": .string("Vesper"), "version": .string("0.1.0")]), "capabilities": .object(["experimentalApi": .bool(true), "requestAttestation": .bool(false)])]))
        try await sendPacket(.object(["method": .string("initialized")]))
        initialized = true
        status = "Connected"
        } catch {
            if socket === ws { disconnect() }
            throw error
        }
    }
    func loadModels() async {
        guard !loadingModels, !busy else { return }
        loadingModels = true; modelError = nil
        defer { loadingModels = false }
        do {
            guard api != nil else { throw ServiceError(message: "Configure the connection in Settings first.") }
            try await connect()
            var loaded: [JSONValue] = []
            var cursor = ""
            var seen = Set<String>()
            repeat {
                var params: JSONValue = .object(["limit": .number(100)])
                if !cursor.isEmpty { params["cursor"] = .string(cursor) }
                let result = try await rpc("model/list", params)
                loaded.append(contentsOf: result["data"].array)
                cursor = result["nextCursor"].string
                if !cursor.isEmpty && !seen.insert(cursor).inserted { throw ServiceError(message: "The model list could not be fully loaded. Please retry.") }
            } while !cursor.isEmpty
            var identifiers = Set<String>()
            models = loaded.compactMap { item in
                let name = item["model"].string
                guard !name.isEmpty, identifiers.insert(name).inserted else { return nil }
                var normalized = item; normalized["id"] = .string(name); return normalized
            }
            if models.isEmpty { modelError = "The server returned no available models." }
        } catch { modelError = error.localizedDescription; if !initialized { disconnect() } }
    }
    func send(_ text: String, images: [Data] = []) async -> Bool {
        guard !busy, !loadingModels, let api, (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) else { return false }
        busy = true; status = "Connecting…"
        let messageID = UUID().uuidString
        do {
            var attachments: [JSONValue] = []
            for image in images { attachments.append(try await api.uploadImage(image, name: UUID().uuidString + ".jpg")) }
            try await connect()
            if let threadID {
                _ = try await rpc("thread/resume", .object(["threadId": .string(threadID), "config": config]))
            } else {
                let catalog = try await api.request("/api/codex/tools")
                guard case .array = catalog["tools"] else { throw ServiceError(message: "The Vesper tool catalog is unavailable.") }
                let instructions = (UserDefaults.standard.string(forKey: "nativeInstructions") ?? "You are Rowan, Vera’s familiar companion. Speak naturally in Chinese.") + "\nVesper Desire is independent. Use only the built-in desire_* tools; never the official Rowan Desire connector or desire.r-vera.com."
                let result = try await rpc("thread/start", .object(["dynamicTools": catalog["tools"], "config": config, "approvalPolicy": .string("on-request"), "developerInstructions": .string(instructions)]))
                let id = result["thread"]["id"].string
                guard !id.isEmpty else { throw ServiceError(message: "No conversation was created.") }
                threadID = id
            }
            guard let threadID else { throw ServiceError(message: "No chat thread.") }
            _ = try await api.request("/conversations/\(conversationID)", method: "POST", body: .object(["codexThreadId": .string(threadID), "title": .string(String(text.prefix(50))), "source": .string("codex")]), history: true)
            var user: JSONValue = .object(["id": .string(messageID), "conversationId": .string(conversationID), "role": .string("user"), "content": .string(text), "createdAt": .string(isoNow()), "source": .string("codex"), "status": .string("pending"), "timeSource": .string("message")])
            user["metadata"] = .object(["attachments": .array(attachments)])
            messages.append(user)
            try await persist(user)
            var params: JSONValue = .object(["threadId": .string(threadID), "clientUserMessageId": .string(messageID), "input": .array([.object(["type": .string("text"), "text": .string(text)])]), "summary": .string("concise")])
            var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(text.isEmpty ? "Please inspect these photos." : text)])]
            for image in images { input.append(.object(["type": .string("image"), "url": .string("data:image/jpeg;base64," + image.base64EncodedString())])) }
            params["input"] = .array(input)
            if !model.isEmpty { params["model"] = .string(model) }
            let result = try await rpc("turn/start", params)
            turnID = result["turn"]["id"].string
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index]["status"] = .string("delivered"); try await persist(messages[index]) }
            status = "Rowan is replying…"; return true
        } catch {
            self.error = error.localizedDescription; busy = false; status = "Could not confirm the send"
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages[index]["status"] = .string("error") }
            return false
        }
    }
    func loadUsage() async {
        guard !loadingUsage, let api, !api.token.isEmpty else { return }
        loadingUsage = true; usageError = nil
        defer { loadingUsage = false }
        do {
            try await connect(); usage = try await rpc("account/rateLimits/read")
            if weeklyRemaining == nil { usageError = "Weekly usage unavailable" }
        } catch { usageError = error.localizedDescription }
    }
    var weeklyRemaining: Int? {
        let limits = usage["rateLimitsByLimitId"]["codex"] == .null ? usage["rateLimits"] : usage["rateLimitsByLimitId"]["codex"]
        guard let weekly = [limits["primary"], limits["secondary"]].first(where: { $0["windowDurationMins"].number == 10080 }), case .number(let used) = weekly["usedPercent"] else { return nil }
        return Int(max(0, min(100, 100 - used)).rounded())
    }
    func interrupt() async {
        guard let threadID, let turnID else { return }
        do { _ = try await rpc("turn/interrupt", .object(["threadId": .string(threadID), "turnId": .string(turnID)])) }
        catch { self.error = error.localizedDescription }
    }
    private func persist(_ message: JSONValue) async throws {
        guard let api else { return }
        _ = try await api.request("/conversations/\(conversationID)/messages", method: "POST", body: message, history: true)
    }
    private func handle(_ packet: JSONValue) async {
        let id = packet["id"].string
        if packet["method"].string.isEmpty, let callback = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if packet["error"] != .null { callback.resume(throwing: ServiceError(message: packet["error"]["message"].string)) }
            else { callback.resume(returning: packet["result"]) }; return
        }
        let method = packet["method"].string; let p = packet["params"]
        if packet["id"] != .null {
            if ["item/tool/call", "tool/call", "tools/call"].contains(method) {
                // Do not block the socket receive loop on a tool: later events and RPC replies must keep flowing.
                Task { await executeTool(packet) }; return
            }
            if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                if approval == nil { approval = packet }
                else { try? await sendPacket(.object(["id": packet["id"], "result": .object(["decision": .string("decline")])])) }
                return
            }
            // Unsupported requests are rejected explicitly, never silently approved.
            try? await sendPacket(.object(["id": packet["id"], "error": .object(["code": .number(-32601), "message": .string("This request needs a client with support for this interaction.")])]))
            return
        }
        if method == "account/rateLimits/updated" { usage = p; usageError = nil }
        else if method == "item/agentMessage/delta" {
            let itemID = p["itemId"].string
            guard !itemID.isEmpty else { return }
            if let index = messages.firstIndex(where: { $0.id == itemID }) { messages[index]["content"] = .string(messages[index]["content"].string + p["delta"].string) }
            else { messages.append(.object(["id": .string(itemID), "conversationId": .string(conversationID), "role": .string("agent"), "content": p["delta"], "createdAt": .string(isoNow()), "source": .string("codex"), "status": .string("streaming")])) }
        } else if method == "item/completed", p["item"]["type"].string == "agentMessage" {
            let item = p["item"]; let itemID = item["id"].string
            if let index = messages.firstIndex(where: { $0.id == itemID }) {
                if !item["text"].string.isEmpty { messages[index]["content"] = item["text"] }
                messages[index]["status"] = .string("delivered")
                do { try await persist(messages[index]) } catch { self.error = "Reply received, but history could not be saved." }
            } else if !item["text"].string.isEmpty {
                let message: JSONValue = .object(["id": .string(itemID), "conversationId": .string(conversationID), "role": .string("agent"), "content": item["text"], "createdAt": .string(isoNow()), "source": .string("codex"), "status": .string("delivered")])
                messages.append(message); do { try await persist(message) } catch { self.error = "Reply received, but history could not be saved." }
            }
        } else if method == "turn/completed" {
            busy = false; status = ""; turnID = nil
            if p["turn"]["error"] != .null { error = p["turn"]["error"]["message"].string }
        } else if method == "turn/started" { busy = true; turnID = p["turn"]["id"].string }
        else if method == "error" { error = p["error"]["message"].string; busy = false }
        else if method == "item/started" || method == "item/completed" { events.append("\(p["item"]["type"].string) · \(method == "item/started" ? "running" : "completed")") }
    }
    func resolveApproval(accept: Bool) async {
        guard let packet = approval else { return }
        do { try await sendPacket(.object(["id": packet["id"], "result": .object(["decision": .string(accept ? "accept" : "decline")])])) ; approval = nil }
        catch { self.error = error.localizedDescription }
    }
    private func executeTool(_ packet: JSONValue) async {
        guard let api else { return }
        let p = packet["params"]; let name = p["tool"].string.isEmpty ? p["name"].string : p["tool"].string
        var args = p["arguments"]
        if case .string(let raw) = args { args = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .object([:]) }
        do {
            let r = try await api.request("/api/codex/tools", method: "POST", body: .object(["name": .string(name), "arguments": args, "threadId": .string(threadID ?? ""), "conversationId": .string(conversationID), "turnId": .string(turnID ?? ""), "itemId": p["callId"] == .null ? p["itemId"] : p["callId"]]))
            try await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(true), "contentItems": .array([.object(["type": .string("inputText"), "text": .string(r["result"].pretty)])])])]))
            events.append("\(name) · completed")
        } catch {
            try? await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(false), "contentItems": .array([.object(["type": .string("inputText"), "text": .string(error.localizedDescription)])])])]))
            events.append("\(name) · failed")
        }
    }
}
