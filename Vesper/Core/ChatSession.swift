import Foundation
import SwiftUI
import UserNotifications
import AVFoundation

@MainActor final class ChatSession: ObservableObject {
    @Published var incomingCall = false
    @Published var callActive = false
    private var notifiedMessages = Set<String>()
    @Published var thinkingSummary = ""
    @Published var messages: [JSONValue] = []
    @Published var conversations: [JSONValue] = []
    @Published var models: [JSONValue] = []
    @Published var loadingModels = false
    @Published var modelError: String?
    @Published var usageUpdatedAt: Date?
    @Published var usage: JSONValue = .null
    @Published var loadingUsage = false
    @Published var usageError: String?
    private var connectionTask: Task<Void, Error>?
    @Published var model = ""
    @Published var effort = ""
    private var restoringLatest = false
    var supportedEfforts: [String] {
        models.first(where: { $0["model"].string == model })?["supportedReasoningEfforts"].array.compactMap {
            let value = $0["reasoningEffort"].string
            return value.isEmpty ? nil : value
        } ?? []
    }
    func selectModel(_ value: String) {
        model = value
        let defaultEffort = models.first(where: { $0["model"].string == value })?["defaultReasoningEffort"].string ?? ""
        effort = supportedEfforts.contains(defaultEffort) ? defaultEffort : ""
    }
    func openLatestConversation() async {
        guard !busy, !restoringLatest else { return }
        restoringLatest = true
        defer { restoringLatest = false }
        await loadConversations()
        guard !Task.isCancelled, !busy, let latest = conversations.sorted(by: {
            ($0["updatedAt"].string.isEmpty ? $0["createdAt"].string : $0["updatedAt"].string) >
            ($1["updatedAt"].string.isEmpty ? $1["createdAt"].string : $1["updatedAt"].string)
        }).first else { return }
        if latest.id != conversationID || messages.isEmpty { await open(latest) }
    }
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var approval: JSONValue?
    @Published var events: [String] = []
    private(set) var conversationID = UUID().uuidString
    private var tombstones: [JSONValue] = []
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
    private weak var appStore: AppStore?
    func configure(_ store: AppStore) { appStore = store; api = store.api; endpoint = store.socketURL }
    func loadConversations() async {
        guard let api else { return }
        do { let r = try await api.request("/conversations", history: true); conversations = r["conversations"].array }
        catch { self.error = error.localizedDescription }
    }
    func renameConversation(_ item: JSONValue, title: String) async {
        guard !busy, let api else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try await api.request("/conversations/\(item.id)", method: "PATCH", body: .object(["title": .string(String(name.prefix(120)))]), history: true)
            await loadConversations()
        } catch { self.error = error.localizedDescription }
    }
    func removeConversation(_ item: JSONValue) async {
        guard !busy, !callActive, let api else { return }
        do {
            _ = try await api.request("/conversations/\(item.id)", method: "DELETE", history: true)
            if conversationID == item.id { newConversation() }
            await loadConversations()
        } catch { self.error = error.localizedDescription }
    }
    func open(_ conversation: JSONValue) async {
        guard !busy, let api else { return }
        disconnect(); conversationID = conversation.id; threadID = nil; messages = []; events = []; thinkingSummary = ""; tombstones = []
        busy = true
        defer { busy = false }
        do {
            let r = try await api.request("/conversations/\(conversationID)", history: true)
            let t = r["conversation"]["codexThreadId"].string
            threadID = t.isEmpty ? nil : t
            tombstones = r["tombstones"].array
            messages = r["messages"].array
            status = "History loaded"
            if let threadID {
                do {
                    try await connect()
                    let snapshot = try await rpc("thread/resume", .object(["threadId": .string(threadID), "config": config]))
                    messages = UserHistoryRecovery.merge(messages, snapshot: snapshot, conversationID: conversationID, tombstones: tombstones)
                    status = "History loaded"
                } catch {
                    self.error = "Saved history is visible, but the full conversation could not be loaded: " + error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func createConversation() async -> Bool {
        guard !busy, !loadingModels, let api else { return false }
        let id = UUID().uuidString
        busy = true
        do {
            _ = try await api.request("/conversations/\(id)", method: "POST", body: .object(["title": .string("New conversation"), "source": .string("codex")]), history: true)
            busy = false; newConversation(); conversationID = id
            await loadConversations(); return true
        } catch { busy = false; self.error = error.localizedDescription; return false }
    }
    func deleteMessage(_ message: JSONValue) async {
        guard !busy, let api else { return }
        do {
            _ = try await api.request("/conversations/\(conversationID)/messages/\(message.id)", method: "DELETE", body: .object(["messageId": .string(message.id), "itemId": message["metadata"]["itemId"], "threadId": message["metadata"]["threadId"] == .null ? .string(threadID ?? "") : message["metadata"]["threadId"]]), history: true)
            tombstones.append(.object(["messageId": .string(message.id), "itemId": message["metadata"]["itemId"]]))
            messages.removeAll { $0.id == message.id }
        } catch { self.error = error.localizedDescription }
    }
    func newConversation() {
        guard !busy else { return }; disconnect(); conversationID = UUID().uuidString; threadID = nil; turnID = nil; messages = []; events = []; thinkingSummary = ""; status = "New conversation"
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
            if !effort.isEmpty && !supportedEfforts.contains(effort) { effort = "" }
            if models.isEmpty { modelError = "The server returned no available models." }
        } catch { modelError = error.localizedDescription; if !initialized { disconnect() } }
    }
    func send(_ text: String, images: [Data] = [], files: [ChatFile] = [], music: JSONValue? = nil, sticker: JSONValue? = nil) async -> Bool {
        guard !busy, !loadingModels, let api, (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty || music != nil || sticker != nil) else { return false }
        busy = true; status = "Connecting…"; thinkingSummary = ""; events = []; error = nil
        let messageID = UUID().uuidString
        do {
            var attachments: [JSONValue] = []
            for image in images { attachments.append(try await api.uploadImage(image, name: UUID().uuidString + ".jpg")) }
            var fileContext = ""
            for file in files {
                let attachment = try await api.uploadFile(file.data, name: file.name, mime: file.mime)
                var decorated = attachment
                decorated["type"] = .string(file.mime)
                if let transcript = file.transcript { decorated["transcript"] = .string(transcript); decorated["duration"] = .number(file.duration ?? 0) }
                attachments.append(decorated)
                if let transcript = file.transcript { fileContext += "\nVoice transcript: " + (transcript.isEmpty ? "Unavailable; do not invent the audio contents." : transcript) }
                fileContext += "\nAttachment: \(file.name) (\(file.mime))\nDownload: \(attachment["url"].string)"
                if file.mime.hasPrefix("text/") || ["application/json", "application/xml"].contains(file.mime), let preview = String(data: file.data, encoding: .utf8) { fileContext += "\nFile preview:\n" + String(preview.prefix(120000)) }
            }
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            if let threadID {
                let snapshot = try await rpc("thread/resume", .object(["threadId": .string(threadID), "config": config]))
                messages = UserHistoryRecovery.merge(messages, snapshot: snapshot, conversationID: conversationID, tombstones: tombstones)
            } else {
                let catalog = try await api.request("/api/codex/tools")
                guard case .array = catalog["tools"] else { throw ServiceError(message: "The Vesper tool catalog is unavailable.") }
                let instructions = (UserDefaults.standard.string(forKey: "nativeInstructions") ?? "You are Rowan, Vera’s familiar companion. Speak naturally in Chinese.") + "\nVesper Desire is independent. Use only the built-in desire_* tools; never the official Rowan Desire connector or desire.r-vera.com."
                let result = try await rpc("thread/start", .object(["dynamicTools": .array(try NativeToolCatalog.normalize(catalog["tools"].array.filter { !["request_native_call", "read_native_health", "send_native_voice"].contains($0["name"].string) } + [Self.callTool, Self.healthTool, Self.voiceTool])), "config": config, "approvalPolicy": .string("on-request"), "developerInstructions": .string(instructions)]))
                let id = result["thread"]["id"].string
                guard !id.isEmpty else { throw ServiceError(message: "No conversation was created.") }
                threadID = id
            }
            guard let threadID else { throw ServiceError(message: "No chat thread.") }
            _ = try await api.request("/conversations/\(conversationID)", method: "POST", body: .object(["codexThreadId": .string(threadID), "title": .string(conversations.first(where: { $0.id == conversationID })?["title"].string ?? String(text.prefix(50))), "source": .string("codex")]), history: true)
            var user: JSONValue = .object(["id": .string(messageID), "conversationId": .string(conversationID), "role": .string("user"), "content": .string(text), "createdAt": .string(isoNow()), "source": .string("codex"), "status": .string("pending"), "timeSource": .string("message")])
            var musicContext = ""
            if let music {
                let title = music["title"].string
                let artist = music["artist"].string
                let songID = music["neteaseId"].string
                musicContext = "\nShared music: \(title) — \(artist) (song ID: \(songID))"
            }
            let stickerContext = sticker.map { "Shared sticker: " + $0["name"].string + " " + $0["description"].string + " (assetId: " + $0["assetId"].string + ")" }
            let modelInputText = (stickerContext ?? (text.isEmpty ? (music == nil ? "Please inspect the attachments." : "Listen with me.") : text)) + fileContext + musicContext
            user["metadata"] = .object(["attachments": .array(attachments), "modelInputText": .string(modelInputText)])
            if let sticker { user["type"] = .string("sticker"); user["metadata"]["sticker"] = sticker }
            if let music { user["metadata"]["musicCard"] = music; user["metadata"]["musicOnly"] = .bool(text.isEmpty); if text.isEmpty { user["content"] = .string("Shared music: " + music["title"].string) } }
            messages.append(user)
            try await persist(user)
            var params: JSONValue = .object(["threadId": .string(threadID), "clientUserMessageId": .string(messageID), "input": .array([.object(["type": .string("text"), "text": .string(text)])]), "summary": .string("concise")])
            var input: [JSONValue] = [.object(["type": .string("text"), "text": .string(modelInputText)])]
            for image in images { input.append(.object(["type": .string("image"), "url": .string("data:image/jpeg;base64," + image.base64EncodedString())])) }
            if let sticker { input.append(.object(["type": .string("image"), "url": sticker["url"]])) }
            params["input"] = .array(input)
            if !model.isEmpty { params["model"] = .string(model) }
            if !effort.isEmpty {
                guard supportedEfforts.contains(effort) else { throw ServiceError(message: "Select an available reasoning effort for this model.") }
                params["effort"] = .string(effort)
            }
            try Task.checkCancellation()
            let result = try await rpc("turn/start", params)
            turnID = result["turn"]["id"].string
            if let index = messages.firstIndex(where: { $0.id == messageID }) {
                messages[index]["status"] = .string("delivered")
                messages[index]["metadata"]["turnId"] = .string(turnID ?? "")
                messages[index]["metadata"]["threadId"] = .string(threadID)
                try await persist(messages[index])
            }
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
            try await connect(); usage = try await rpc("account/rateLimits/read"); usageUpdatedAt = Date()
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
    private static let healthTool: JSONValue = .object([
        "name": .string("read_native_health"), "description": .string("Read fresh, authorized HealthKit summaries from Vera's current iPhone: steps, sleep, heart rate and wrist temperature. Missing data does not prove permission was denied. Requires the native app; do not claim access to other health data."),
        "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    ])
    private static let voiceTool: JSONValue = .object([
        "name": .string("send_native_voice"), "description": .string("Send Vera an audio message synthesized using her configured ElevenLabs/MiniMax voice. Include the exact spoken text. Success means the audio message was saved, not listened to."),
        "inputSchema": .object(["type": .string("object"), "properties": .object(["text": .object(["type": .string("string")])]), "required": .array([.string("text")]), "additionalProperties": .bool(false)])
    ])
    private static let callTool: JSONValue = .object([
        "name": .string("request_native_call"),
        "description": .string("Invite Vera to a voice call in the currently open native app. Only an invitation: she must accept and start. Not a background/phone-network call. Do not report that she answered. Available only in native threads created with this tool."),
        "inputSchema": .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)])
    ])
    func saveCall(start: Date, end: Date, video: Bool, transcript: [JSONValue], target: String, initiator: String = "user") async {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let title = "\(video ? "Video" : "Voice") call · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        let message: JSONValue = .object(["id": .string("call-" + UUID().uuidString), "conversationId": .string(target), "role": .string(initiator == "agent" ? "agent" : "user"), "content": .string(title), "createdAt": .string(ISO8601DateFormatter().string(from: end)), "source": .string("vesper"), "status": .string("delivered"), "metadata": .object(["showTurnStatus": .bool(false), "call": .object(["startedAt": .string(ISO8601DateFormatter().string(from: start)), "endedAt": .string(ISO8601DateFormatter().string(from: end)), "transcript": .array(transcript), "video": .bool(video), "initiator": .string(initiator)])])])
        if conversationID == target { messages.append(message) }
        do {
            guard let api else { throw ServiceError(message: "Not connected") }
            _ = try await api.request("/conversations/\(target)/messages", method: "POST", body: message, history: true)
        } catch { self.error = "Call ended, but its record could not be synced: " + error.localizedDescription }
    }
    private func notifyReply(_ message: JSONValue) async {
        guard !message.id.isEmpty, notifiedMessages.insert(message.id).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = "Rowan"; content.body = String(message["content"].string.prefix(180))
        if content.body.isEmpty { content.body = "Sent you an attachment" }
        content.sound = .default; content.threadIdentifier = conversationID
        content.userInfo = ["conversationId": conversationID]
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "message-" + message.id, content: content, trigger: nil)) }
        catch { self.error = "Message received; notification could not be displayed: " + error.localizedDescription }
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
        if method == "account/rateLimits/updated" { usage = p; usageError = nil; usageUpdatedAt = Date() }
        else if method == "item/reasoning/summaryTextDelta" {
            thinkingSummary += p["delta"].string
        }
        else if method == "item/commandExecution/outputDelta" || method == "item/fileChange/outputDelta" {
            let id = p["itemId"].string
            if let index = messages.firstIndex(where: { $0.id == "execution-" + id }) {
                let old = messages[index]["metadata"]["execution"]["output"].string
                messages[index]["metadata"]["execution"]["output"] = .string(old + p["delta"].string)
            }
        }
        else if (method == "item/started" || method == "item/completed"), ["commandExecution", "fileChange", "shellCall"].contains(p["item"]["type"].string) {
            let item = p["item"]; let id = item["id"].string
            guard !id.isEmpty else { return }
            let index = messages.firstIndex(where: { $0.id == "execution-" + id })
            var execution = index.map { messages[$0]["metadata"]["execution"] } ?? .object([:])
            execution["type"] = item["type"]
            execution["title"] = .string(item["command"].string.isEmpty ? (item["type"].string == "fileChange" ? "File changes" : "Terminal") : item["command"].string)
            execution["status"] = .string(item["status"].string.isEmpty ? (method == "item/started" ? "running" : "completed") : item["status"].string)
            for key in ["command", "cwd", "exitCode", "durationMs"] { if item[key] != .null { execution[key] = item[key] } }
            if item["aggregatedOutput"] != .null { execution["output"] = item["aggregatedOutput"] }
            if item["changes"] != .null { execution["files"] = item["changes"] }
            let message: JSONValue = .object(["id": .string("execution-" + id), "conversationId": .string(conversationID), "role": .string("system"), "content": .string(execution["title"].string), "createdAt": .string(index.map { messages[$0]["createdAt"].string } ?? isoNow()), "source": .string("codex"), "metadata": .object(["blockType": item["type"], "execution": execution, "turnId": .string(turnID ?? ""), "threadId": .string(threadID ?? "")])])
            if let index { messages[index] = message } else { messages.append(message) }
            if method == "item/completed" { do { try await persist(message) } catch { self.error = "Terminal output received, but history could not be saved." } }
        }
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
                messages[index]["metadata"]["threadId"] = .string(threadID ?? "")
                messages[index]["metadata"]["turnId"] = .string(turnID ?? "")
                messages[index]["metadata"]["thoughtSummary"] = .string(thinkingSummary)
                messages[index]["metadata"]["toolEvents"] = .array(events.map { .string($0) })
                do { try await persist(messages[index]) } catch { self.error = "Reply received, but history could not be saved." }
            } else if !item["text"].string.isEmpty {
                let message: JSONValue = .object(["id": .string(itemID), "conversationId": .string(conversationID), "role": .string("agent"), "content": item["text"], "createdAt": .string(isoNow()), "source": .string("codex"), "status": .string("delivered")])
                var savedMessage = message
                savedMessage["metadata"] = .object(["threadId": .string(threadID ?? ""), "turnId": .string(turnID ?? ""), "thoughtSummary": .string(thinkingSummary), "toolEvents": .array(events.map { .string($0) })])
                messages.append(savedMessage); do { try await persist(savedMessage) } catch { self.error = "Reply received, but history could not be saved." }
            }
            if let message = messages.first(where: { $0.id == itemID }) { await notifyReply(message) }
        } else if method == "turn/completed" {
            if !thinkingSummary.isEmpty || !events.isEmpty, let index = messages.lastIndex(where: { $0["role"].string == "agent" && $0["status"].string == "delivered" }) {
                messages[index]["metadata"]["thoughtSummary"] = .string(thinkingSummary)
                messages[index]["metadata"]["toolEvents"] = .array(events.map { .string($0) })
                do { try await persist(messages[index]); thinkingSummary = "" } catch { self.error = "Reply received, but the thinking summary could not be saved." }
            }
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
        let targetConversation = conversationID
        let targetThread = threadID ?? ""
        let targetTurn = turnID ?? ""
        let callID = p["callId"].string.isEmpty ? (p["itemId"].string.isEmpty ? packet["id"].pretty : p["itemId"].string) : p["callId"].string
        var args = p["arguments"]
        if case .string(let raw) = args { args = (try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))) ?? .object([:]) }
        do {
            if name == "read_native_health" {
                let reader = HealthReader(); await reader.refresh()
                let result = reader.snapshot
                try await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(reader.available), "contentItems": .array([.object(["type": .string("inputText"), "text": .string(result.pretty)])])])]))
                events.append("read_native_health · completed")
                return
            }
            if name == "send_native_voice" {
                guard let store = appStore else { throw ServiceError(message: "Device is not connected") }
                let text = args["text"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 5000 else { throw ServiceError(message: "Voice text must contain 1–5000 characters") }
                let connection = VoiceConfiguration.normalized(VoiceConfiguration.connection(store))
                guard !connection["apiKey"].string.isEmpty else { throw ServiceError(message: "Configure your voice in Settings first") }
                var request = URLRequest(url: try APIClient.validatedURL(store.baseURL, path: "/api/tts"))
                request.httpMethod = "POST"; request.timeoutInterval = 60
                request.setValue(store.token, forHTTPHeaderField: "x-vesper-device-token")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(JSONValue.object(["text": .string(text), "connection": connection]))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServiceError(message: VoiceConfiguration.failure(data, response: response, connection: connection)) }
                let audio = try AVAudioPlayer(data: data)
                var attachment = try await api.uploadFile(data, name: "Rowan-voice.mp3", mime: "audio/mpeg")
                attachment["type"] = .string("audio/mpeg"); attachment["transcript"] = .string(text); attachment["duration"] = .number(audio.duration)
                let message: JSONValue = .object(["id": .string("voice:" + targetThread + ":" + callID), "conversationId": .string(targetConversation), "role": .string("agent"), "content": .string(text), "createdAt": .string(isoNow()), "status": .string("delivered"), "metadata": .object(["attachments": .array([attachment]), "voiceMessage": .bool(true)])])
                _ = try await api.request("/conversations/\(targetConversation)/messages", method: "POST", body: message, history: true)
                if targetConversation == conversationID { if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message } else { messages.append(message) }; await notifyReply(message) }
                try await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(true), "contentItems": .array([.object(["type": .string("inputText"), "text": .string("Voice message saved with transcript")])])])]))
                events.append("send_native_voice · completed")
                return
            }
            if name == "request_native_call" {
                guard UIApplication.shared.applicationState == .active, !callActive, !incomingCall else { throw ServiceError(message: "Vera cannot receive an in-app call invitation right now.") }
                try await SystemCalls.shared.incoming()
                try await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(true), "contentItems": .array([.object(["type": .string("inputText"), "text": .string("Incoming call reported to CallKit; not answered yet.")])])])]))
                events.append("request_native_call · invitation displayed")
                return
            }
            let r = try await api.request("/api/codex/tools", method: "POST", body: .object(["name": .string(name), "arguments": args, "threadId": .string(threadID ?? ""), "conversationId": .string(conversationID), "turnId": .string(turnID ?? ""), "itemId": p["callId"] == .null ? p["itemId"] : p["callId"]]))
            if name == "sticker_send" {
                let sticker = r["result"]["stickerMessage"]
                guard !sticker["assetId"].string.isEmpty, !sticker["url"].string.isEmpty, !sticker["mimeType"].string.isEmpty else { throw ServiceError(message: "The tool returned no sticker; delivery was not confirmed.") }
                let id = "sticker:\(targetThread):\(callID)"
                let existing = messages.first(where: { $0.id == id })
                let message: JSONValue = .object(["id": .string(id), "conversationId": .string(targetConversation), "role": .string("agent"), "type": .string("sticker"), "content": .string(""), "createdAt": .string(existing?["createdAt"].string ?? isoNow()), "status": .string("delivered"), "metadata": .object(["sticker": sticker, "showTurnStatus": .bool(false), "threadId": .string(targetThread), "turnId": .string(targetTurn)])])
                _ = try await api.request("/conversations/\(targetConversation)/messages", method: "POST", body: message, history: true)
                if targetConversation == conversationID {
                    if let index = messages.firstIndex(where: { $0.id == id }) { messages[index] = message } else { messages.append(message) }
                    await notifyReply(message)
                }
            }
            if ["send_chat_file", "album_send_photos"].contains(name) {
                let result = r["result"]
                guard !result["attachments"].array.isEmpty else { throw ServiceError(message: "The tool returned no attachments; file delivery was not confirmed.") }
                let fileID = "files:\(targetThread):\(callID)"
                let existing = targetConversation == conversationID ? messages.first(where: { $0.id == fileID }) : nil
                let fileMessage = ChatFileDelivery.message(result, conversationID: targetConversation, threadID: targetThread, turnID: targetTurn, callID: callID, createdAt: existing?["createdAt"].string ?? isoNow())
                // Confirm persistence before reporting successful delivery to the model.
                _ = try await api.request("/conversations/\(targetConversation)/messages", method: "POST", body: fileMessage, history: true)
                if targetConversation == conversationID {
                    if let index = messages.firstIndex(where: { $0.id == fileMessage.id }) { messages[index] = fileMessage }
                    else { messages.append(fileMessage) }
                    await notifyReply(fileMessage)
                }
            }
            try await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(true), "contentItems": .array([.object(["type": .string("inputText"), "text": .string(r["result"].pretty)])])])]))
            events.append("\(name) · completed")
        } catch {
            if name == "request_native_call" {
                events.append("request_native_call · failed\n" + error.localizedDescription)
            } else { events.append("\(name) · failed") }
            try? await sendPacket(.object(["id": packet["id"], "result": .object(["success": .bool(false), "contentItems": .array([.object(["type": .string("inputText"), "text": .string(error.localizedDescription)])])])]))
        }
    }
}

/// Restore only public reasoning summaries and tool statuses supplied by the server.
/// Match saved assistant messages by stable item ID; never recreate deleted messages.
enum ChatDetailRecovery {
    static func restore(_ saved: [JSONValue], snapshot: JSONValue) -> [JSONValue] {
        let thread = snapshot["thread"] == .null ? snapshot : snapshot["thread"]
        var result = saved
        for turn in thread["turns"].array {
            var summaries: [String] = []
            var tools: [String] = []
            for item in turn["items"].array {
                let kind = item["type"].string
                if kind == "reasoning" {
                    for part in item["summary"].array {
                        let text = part.string.isEmpty ? part["text"].string : part.string
                        if !text.isEmpty { summaries.append(text) }
                    }
                }
                if ["dynamicToolCall", "mcpToolCall", "commandExecution", "fileChange", "shellCall"].contains(kind) {
                    let name = item["tool"].string.isEmpty ? (item["name"].string.isEmpty ? kind : item["name"].string) : item["tool"].string
                    let status = item["status"].string
                    tools.append(name + (status.isEmpty ? "" : " · " + status))
                }
                guard kind == "agentMessage", !item.id.isEmpty,
                      let index = result.firstIndex(where: { $0["role"].string == "agent" && ($0.id == item.id || $0["metadata"]["itemId"].string == item.id) }) else { continue }
                result[index]["metadata"]["turnId"] = .string(turn.id)
                result[index]["metadata"]["threadId"] = thread["id"]
                if result[index]["metadata"]["thoughtSummary"].string.isEmpty && !summaries.isEmpty {
                    result[index]["metadata"]["thoughtSummary"] = .string(summaries.joined(separator: "\n"))
                }
                if result[index]["metadata"]["toolEvents"].array.isEmpty && !tools.isEmpty {
                    result[index]["metadata"]["toolEvents"] = .array(tools.map { .string($0) })
                }
            }
        }
        return result
    }
}

/// Recover user-authored items from the same snapshot used by the web client.
/// Do not replace saved bubbles, invent timestamps, or resurrect deleted items.
enum UserHistoryRecovery {
    static func parsedTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func timestamp(_ value: JSONValue) -> String {
        if case .number(let number) = value {
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number))
        }
        return value.string
    }
    static func merge(_ saved: [JSONValue], snapshot: JSONValue, conversationID: String, tombstones: [JSONValue]) -> [JSONValue] {
        let thread = snapshot["thread"] == .null ? snapshot : snapshot["thread"]
        var entries: [(JSONValue, String, JSONValue)] = (thread["items"].array + thread["messages"].array).map { ($0, "", .null) }
        for turn in thread["turns"].array {
            entries += turn["items"].array.map { ($0, turn.id, turn["startedAt"] == .null ? turn["createdAt"] : turn["startedAt"]) }
        }
        var result = ChatDetailRecovery.restore(saved, snapshot: snapshot)
        for (item, turnID, turnTime) in entries {
            guard item["role"].string == "user" || ["userMessage", "userInput"].contains(item["type"].string), !item.id.isEmpty else { continue }
            let chunks = item["content"].array.map { $0["text"].string }.joined()
            let text = (item["text"].string.isEmpty ? (item["content"].string.isEmpty ? chunks : item["content"].string) : item["text"].string).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.lowercased().hasPrefix("[vesper response preference — not user content:"), !text.hasPrefix("旧记忆背景（只作为长期背景") else { continue }
            if tombstones.contains(where: { $0["messageId"].string == item.id || $0["stableId"].string == item.id || $0["itemId"].string == item.id }) { continue }
            // Older native messages did not save the turn ID or expanded model input.
            // Match only the exact generated attachment header and its upload URL,
            // never a generic "Attachment:" phrase or a caption alone.
            let attachmentMatches = result.indices.filter { index in
                let existing = result[index]
                guard existing["role"].string == "user", !existing["metadata"]["attachments"].array.isEmpty else { return false }
                let existingTurn = existing["metadata"]["turnId"].string
                guard existingTurn.isEmpty || existingTurn == turnID else { return false }
                let caption = existing["content"].string
                let prefix = caption.isEmpty ? "Please inspect the attachments." : caption
                guard text.hasPrefix(prefix + "\nAttachment: ") else { return false }
                return existing["metadata"]["attachments"].array.contains { attachment in
                    let url = attachment["url"].string
                    let name = attachment["name"].string
                    return !url.isEmpty && !name.isEmpty && text.contains("\nAttachment: " + name + " (") && text.contains("\nDownload: " + url)
                }
            }
            if attachmentMatches.count == 1, let index = attachmentMatches.first {
                result[index]["metadata"]["itemId"] = .string(item.id)
                result[index]["metadata"]["turnId"] = .string(turnID)
                continue
            }
            if result.contains(where: { existing in
                existing.id == item.id || existing["metadata"]["itemId"].string == item.id ||
                (!turnID.isEmpty && existing["role"].string == "user" && existing["metadata"]["turnId"].string == turnID && (existing["content"].string == text || existing["metadata"]["modelInputText"].string == text))
            }) { continue }
            let itemTime = item["createdAt"] == .null ? item["startedAt"] : item["createdAt"]
            let time = timestamp(itemTime == .null ? turnTime : itemTime)
            // Correlate legacy local IDs one-to-one. Equal text alone is not
            // identity: require a unique, nearby timestamp and compatible turn.
            if let snapshotDate = parsedTime(time), !turnID.isEmpty {
                let candidates = result.indices.filter { index in
                    let existing = result[index]
                    guard existing["role"].string == "user",
                          existing["metadata"]["itemId"].string.isEmpty,
                          existing["metadata"]["attachments"].array.isEmpty,
                          existing["content"].string.trimmingCharacters(in: .whitespacesAndNewlines) == text,
                          existing["metadata"]["turnId"].string.isEmpty || existing["metadata"]["turnId"].string == turnID,
                          let savedDate = parsedTime(existing["createdAt"].string),
                          abs(savedDate.timeIntervalSince(snapshotDate)) <= 10 else { return false }
                    return true
                }
                if candidates.count == 1, let index = candidates.first {
                    result[index]["metadata"]["itemId"] = .string(item.id)
                    result[index]["metadata"]["turnId"] = .string(turnID)
                    result[index]["metadata"]["threadId"] = thread["id"]
                    continue
                }
            }
            let restored: JSONValue = .object(["id": .string(item.id), "conversationId": .string(conversationID), "role": .string("user"), "content": .string(text), "createdAt": .string(time), "status": .string("delivered"), "source": .string("codex"), "metadata": .object(["itemId": .string(item.id), "turnId": .string(turnID), "threadId": thread["id"], "blockType": item["type"]])])
            if let index = result.firstIndex(where: { !turnID.isEmpty && $0["metadata"]["turnId"].string == turnID }) {
                result.insert(restored, at: index)
            } else if !time.isEmpty, let index = result.firstIndex(where: { !$0["createdAt"].string.isEmpty && $0["createdAt"].string > time }) {
                result.insert(restored, at: index)
            } else { result.append(restored) }
        }
        return result
    }
}


/// Tool-returned attachments are ordinary assistant messages, as on the web client.
enum ChatFileDelivery {
    static func message(_ result: JSONValue, conversationID: String, threadID: String, turnID: String, callID: String, createdAt: String) -> JSONValue {
        let id = "files:\(threadID):\(callID)"
        let caption = result["message"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return .object(["id": .string(id), "conversationId": .string(conversationID), "role": .string("agent"), "content": .string(caption.isEmpty ? "文件" : caption), "status": .string("delivered"), "createdAt": .string(createdAt), "source": .string("codex"), "metadata": .object(["attachments": result["attachments"], "attachmentOnly": .bool(caption.isEmpty), "itemId": .string(id), "threadId": .string(threadID), "turnId": .string(turnID), "blockType": .string("agentMessage"), "showTurnStatus": .bool(false)])])
    }
}


enum NativeToolCatalog {
    static func normalize(_ tools: [JSONValue]) throws -> [JSONValue] {
        try tools.map { tool in
            let value = tool["function"] == .null ? tool : tool["function"]
            let schema = value["inputSchema"] == .null ? value["parameters"] : value["inputSchema"]
            guard !value["name"].string.isEmpty, case .object = schema else { throw ServiceError(message: "Invalid tool definition in Vesper catalog") }
            // All definitions use the same canonical tagged format.
            return .object(["type": .string("function"), "name": value["name"], "description": .string(value["description"].string), "inputSchema": schema])
        }
    }
}
