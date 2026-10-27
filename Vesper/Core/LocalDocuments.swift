import Foundation
import CryptoKit

struct PendingDocument: Codable, Equatable {
    var id = UUID().uuidString
    var base: JSONValue
    var value: JSONValue
}

struct LocalDocumentSnapshot: Codable {
    var documents: [String: JSONValue] = [:]
    var pending: [String: PendingDocument] = [:]
    var lastSync: Date?
}

/// The endpoint and credential identify a replica; credentials never appear in filenames.
struct LocalDocumentDisk {
    var directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalDocuments", isDirectory: true)
    private func file(_ api: APIClient) -> URL {
        let identity = SHA256.hash(data: Data((api.baseURL + "\n" + api.token).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(identity + ".json")
    }
    // The snapshot and destination are value copies; the writer never shares
    // mutable AppStore state with the background queue.
    private struct WriteRequest: @unchecked Sendable {
        let snapshot: LocalDocumentSnapshot
        let destination: URL
    }
    private static let writeQueue = DispatchQueue(label: "vesper.local-documents.write", qos: .userInitiated)
    func load(_ api: APIClient) throws -> LocalDocumentSnapshot? {
        guard !api.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let url = file(api)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LocalDocumentSnapshot.self, from: Data(contentsOf: url))
    }
    func save(_ snapshot: LocalDocumentSnapshot, api: APIClient) throws {
        guard !api.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError(message: "Connect this device before saving local data.")
        }
        try Self.write(snapshot, to: file(api))
    }
    func saveOffMain(_ snapshot: LocalDocumentSnapshot, api: APIClient) async throws {
        guard !api.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError(message: "Connect this device before saving local data.")
        }
        let request = WriteRequest(snapshot: snapshot, destination: file(api))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.writeQueue.async {
                do { try Self.write(request.snapshot, to: request.destination); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func write(_ snapshot: LocalDocumentSnapshot, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

enum DocumentMerge {
    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    struct Conflict: LocalizedError {
        var errorDescription: String? { "This document also changed on another device. Your local version is saved. Choose which changes to keep in Settings › Data." }
    }
    /// Merge changed fields and identified rows, never replace an unrelated remote edit.
    static func apply(base: JSONValue?, local: JSONValue?, remote: JSONValue?, preferLocal: Bool = false) throws -> JSONValue? {
        if local == base { return remote }
        if remote == base || remote == local { return local }
        if case .object(let mine) = local, case .object(let theirs) = remote,
           base == nil || base == .null || { if case .object = base { return true }; return false }() {
            let before = base?.object ?? [:]
            var result = theirs
            for key in Set(before.keys).union(mine.keys) {
                if key == "updatedAt", let a = mine[key]?.string, let b = theirs[key]?.string,
                   let localDate = timestamp(a), let remoteDate = timestamp(b) {
                    result[key] = .string(localDate > remoteDate ? a : b); continue
                }
                result[key] = try apply(base: before[key], local: mine[key], remote: theirs[key], preferLocal: preferLocal)
            }
            return .object(result)
        }
        if case .array(let mine) = local, case .array(let theirs) = remote,
           case .array(let before) = base,
           [before, mine, theirs].allSatisfy({ rows in
               rows.allSatisfy { !$0.id.isEmpty } && Set(rows.map(\.id)).count == rows.count
           }) {
            let b = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let l = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
            let r = Dictionary(uniqueKeysWithValues: theirs.map { ($0.id, $0) })
            var result = r
            for id in Set(b.keys).union(l.keys) {
                result[id] = try apply(base: b[id], local: l[id], remote: r[id], preferLocal: preferLocal)
            }
            // Preserve the remote order unless this device deliberately reordered existing rows.
            let shared = Set(b.keys).intersection(l.keys).intersection(r.keys)
            let oldOrder = before.map(\.id).filter { shared.contains($0) }
            let localOrder = mine.map(\.id).filter { shared.contains($0) }
            let remoteOrder = theirs.map(\.id).filter { shared.contains($0) }
            if localOrder != oldOrder && remoteOrder != oldOrder && localOrder != remoteOrder && !preferLocal { throw Conflict() }
            var order = localOrder != oldOrder ? mine.map(\.id) : mine.filter { b[$0.id] == nil }.map(\.id) + theirs.map(\.id)
            order += mine.map(\.id) + theirs.map(\.id)
            var seen = Set<String>()
            return .array(order.filter { seen.insert($0).inserted }.compactMap { result[$0] })
        }
        if preferLocal { return local }
        throw Conflict()
    }
}

/// Durable history uploads only. Never replays turn/start or sends a message to the model.
@MainActor final class ChatSendOutbox {
    static let shared = ChatSendOutbox()
    struct Entry: Codable {
        var revision = UUID().uuidString
        var conversation: JSONValue
        var message: JSONValue
        // Optional for queues written by older app versions.
        var historySaved: Bool? = nil
        var key: String { message["conversationId"].string + "/" + message.id }
    }
    private final class Lane {
        var entries: [Entry]
        var worker: Task<Void, Never>?
        var retry: Task<Void, Never>?
        var failures = 0
        var error: Error?
        var syncingMemory = false
        var notice: ((String) -> Void)?
        init(_ entries: [Entry]) { self.entries = entries }
    }
    private var lanes: [String: Lane] = [:]
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChatSendOutbox")) {
        self.directory = directory
    }
    private func key(_ api: APIClient) -> String {
        SHA256.hash(data: Data((api.baseURL + "\n" + api.historyURL + "\n" + api.token).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func isEmptyAssistantRecord(_ message: JSONValue) -> Bool {
        guard ["agent", "system"].contains(message["role"].string),
              message["type"].string.isEmpty || message["type"].string == "text" else { return false }
        let metadata = message["metadata"]
        // A completed final answer may intentionally have no visible text.
        // Keep it in history; only discard empty streaming/activity placeholders.
        if message["role"].string == "agent", message["status"].string == "delivered",
           metadata["phase"].string == "final_answer" { return false }
        return message["content"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            metadata["attachments"].array.isEmpty && metadata["sticker"] == .null &&
            metadata["musicCard"] == .null && metadata["locationCard"] == .null &&
            metadata["call"] == .null
    }
    private func lane(_ api: APIClient) throws -> Lane {
        guard !api.token.isEmpty else { throw ServiceError(message: "Connect your device before saving messages.") }
        let id = key(api)
        if let lane = lanes[id] { return lane }
        let url = directory.appendingPathComponent(id + ".json")
        let restored = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url)) : []
        // Earlier versions queued empty streaming/summary placeholders. Keep
        // completed final answers while removing those invalid placeholders.
        let entries = restored.filter { !isEmptyAssistantRecord($0.message) }
        if entries.count != restored.count { try save(entries, api: api) }
        let lane = Lane(entries); lanes[id] = lane; return lane
    }
    private func save(_ entries: [Entry], api: APIClient) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key(api) + ".json")
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func activate(_ api: APIClient, notice: ((String) -> Void)? = nil) {
        guard !api.token.isEmpty else { return }
        do {
            let lane = try lane(api)
            if let notice { lane.notice = notice }
            lane.notice?(syncNotice(lane))
            lane.retry?.cancel(); lane.retry = nil
            start(lane, api: api)
        } catch { notice?("本地待同步记录无法读取：" + error.localizedDescription) }
    }
    func enqueue(_ message: JSONValue, conversation: JSONValue, api: APIClient) throws {
        if isEmptyAssistantRecord(message) { return }
        guard !message.id.isEmpty, !message["conversationId"].string.isEmpty,
              ["user", "agent", "system"].contains(message["role"].string) else { throw ServiceError(message: "Invalid chat record.") }
        let lane = try lane(api)
        let entry = Entry(conversation: conversation, message: message)
        var entries = lane.entries
        if let index = entries.firstIndex(where: { $0.key == entry.key }) { entries[index] = entry }
        else { entries.append(entry) }
        // A failed disk write must leave both the previous queue and the draft intact.
        try save(entries, api: api); lane.entries = entries
        start(lane, api: api)
    }
    func pending(_ api: APIClient, conversationID: String) throws -> [JSONValue] {
        try lane(api).entries.filter { $0.message["conversationId"].string == conversationID }.map(\.message)
    }
    /// A pending turn from days ago must not be prepended to a newer, paginated
    /// history page on every launch. Keep a recoverable copy before retiring it.
    static func stalePendingIDs(_ pending: [JSONValue], newerPage: [JSONValue],
                                hasOlder: Bool, now: Date = Date()) -> Set<String> {
        guard hasOlder else { return [] }
        let parser = ISO8601DateFormatter()
        let pageDates = newerPage.compactMap { parser.date(from: $0["createdAt"].string) }
        guard let oldest = pageDates.min(), let newest = pageDates.max(), newest > oldest else { return [] }
        return Set(pending.compactMap { message in
            guard message["status"].string == "pending", !message.id.isEmpty,
                  let created = parser.date(from: message["createdAt"].string),
                  created < oldest, now.timeIntervalSince(created) > 48 * 60 * 60 else { return nil }
            return message.id
        })
    }
    func quarantineStalePending(_ api: APIClient, conversationID: String,
                                newerPage: [JSONValue], hasOlder: Bool) throws -> Set<String> {
        let lane = try lane(api)
        let pending = lane.entries.filter { $0.message["conversationId"].string == conversationID }.map(\.message)
        let stale = Self.stalePendingIDs(pending, newerPage: newerPage, hasOlder: hasOlder)
        guard !stale.isEmpty else { return [] }
        let retired = lane.entries.filter { $0.message["conversationId"].string == conversationID && stale.contains($0.message.id) }
        let archive = directory.appendingPathComponent(key(api) + ".quarantined.json")
        let previous = FileManager.default.fileExists(atPath: archive.path)
            ? try JSONDecoder().decode([Entry].self, from: Data(contentsOf: archive)) : []
        let existing = Set(previous.map(\.key))
        let backedUp = previous + retired.filter { !existing.contains($0.key) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(backedUp).write(to: archive, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        let remaining = lane.entries.filter { !($0.message["conversationId"].string == conversationID && stale.contains($0.message.id)) }
        try save(remaining, api: api)
        lane.entries = remaining
        return stale
    }
    /// Deletion/renaming waits for queued writes, so a late upload cannot resurrect a message.
    func flush(_ api: APIClient) async throws {
        let lane = try lane(api)
        lane.retry?.cancel(); lane.retry = nil
        start(lane, api: api)
        await lane.worker?.value
        if lane.entries.contains(where: { $0.message["status"].string != "pending" }) {
            throw lane.error ?? ServiceError(message: "Messages are still waiting to sync. Try again when connected.")
        }
    }
    /// Call after flush and the server's delete receipt. Pending entries are never uploaded.
    func discard(_ api: APIClient, conversationID: String, messageID: String? = nil) throws {
        let lane = try lane(api)
        let remaining = lane.entries.filter {
            $0.message["conversationId"].string != conversationID || (messageID != nil && $0.message.id != messageID)
        }
        try save(remaining, api: api); lane.entries = remaining
        if remaining.isEmpty {
            lane.retry?.cancel(); lane.retry = nil
            lane.error = nil; lane.failures = 0; lane.notice?("")
        }
    }
    func stop() {
        for lane in lanes.values { lane.worker?.cancel(); lane.retry?.cancel(); lane.retry = nil }
    }
    private func syncNotice(_ lane: Lane) -> String {
        guard let error = lane.error else { return "" }
        let summary = lane.syncingMemory
            ? "聊天记录已上传，记忆归档暂未完成；会自动重试。"
            : "消息已保存在本机，聊天记录上传暂未完成；会自动重试。"
        let reason: String
        if let failure = error as? ServiceError, let status = failure.statusCode {
            reason = status == 401 ? "服务端认证失败（HTTP 401）" : status == 403 ? "同步请求被服务端拒绝（HTTP 403）" : "服务端返回 HTTP \(status)"
        } else if let failure = error as? URLError {
            switch failure.code {
            case .notConnectedToInternet: reason = "设备当前无法联网"
            case .timedOut: reason = "同步请求超时"
            case .networkConnectionLost: reason = "与同步服务的连接中断"
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: reason = "暂时无法连接同步服务"
            case .cancelled: reason = "同步请求被中断"
            default: reason = "网络请求失败（\(failure.code.rawValue)）"
            }
        } else { reason = "同步服务暂时不可用" }
        return summary + "\n" + reason
    }
    private func start(_ lane: Lane, api: APIClient) {
        guard lane.worker == nil, lane.entries.contains(where: { $0.message["status"].string != "pending" }) else { return }
        lane.worker = Task { [self] in
            defer { lane.worker = nil }
            // The thread mapping needs one receipt per distinct header in this run,
            // not another round trip for every message in a backlog. Retry runs
            // start fresh, and a changed header is always written again.
            var savedConversations: [String: JSONValue] = [:]
            do {
                // Unconfirmed model sends stay on disk; never publish an old pending state
                // over a delivered receipt recovered by another client.
                // Upload new history before retrying secondary memory indexing.
                while let entry = lane.entries.first(where: { $0.message["status"].string != "pending" && $0.historySaved != true })
                    ?? lane.entries.first(where: { $0.message["status"].string != "pending" }) {
                    try Task.checkCancellation()
                    let id = entry.message["conversationId"].string
                    do {
                    let message = entry.message
                    if entry.historySaved != true {
                        lane.syncingMemory = false
                        // Existing server endpoints upsert by conversation/message ID.
                        if savedConversations[id] != entry.conversation {
                            _ = try await api.request("/conversations/\(id)", method: "POST", body: entry.conversation, history: true)
                            savedConversations[id] = entry.conversation
                        }
                        try Task.checkCancellation()
                        guard lane.entries.contains(where: { $0.revision == entry.revision }) else { continue }
                        let receipt = try await api.request("/conversations/\(id)/messages", method: "POST", body: message, history: true)
                        try Task.checkCancellation()
                        guard let index = lane.entries.firstIndex(where: { $0.revision == entry.revision }) else { continue }
                        var checkpoint = lane.entries
                        if receipt["deleted"].bool { checkpoint.remove(at: index) }
                        else { checkpoint[index].historySaved = true }
                        try save(checkpoint, api: api); lane.entries = checkpoint
                        // A previous failure is no longer the current result once
                        // a retry has durably checkpointed a successful upload.
                        clearFailure(lane)
                        continue
                    }
                    lane.syncingMemory = true
                    if message["status"].string == "delivered",
                       ["user", "agent"].contains(message["role"].string), !ChatPresentation.isActivity(message),
                       !message["content"].string.isEmpty || !message["metadata"]["attachments"].array.isEmpty {
                        _ = try await api.request("/api/memory/messages", method: "POST", body: .object([
                            "conversationId": .string(id), "messageId": .string(message.id), "role": message["role"],
                            "content": message["content"], "createdAt": message["createdAt"],
                            "turnId": message["metadata"]["turnId"], "attachments": message["metadata"]["attachments"]]))
                    }
                    try Task.checkCancellation()
                    guard lane.entries.contains(where: { $0.revision == entry.revision }) else { continue }
                    let remaining = lane.entries.filter { $0.revision != entry.revision }
                    try save(remaining, api: api); lane.entries = remaining
                    clearFailure(lane)
                    } catch let failure as ServiceError where failure.conversationDeleted {
                        // A confirmed tombstone is terminal, not a network retry. Never
                        // let an obsolete room block uploads for the remaining rooms.
                        try discard(api, conversationID: id)
                        ChatRecentCache.remove(api: api, id: id)
                    }
                }
                lane.error = nil; lane.failures = 0; lane.notice?("")
            } catch {
                guard !Task.isCancelled else { return }
                lane.error = error; lane.failures += 1
                lane.notice?(syncNotice(lane))
                lane.retry = Task { [self] in
                    do { try await Task.sleep(for: .seconds(min(60, pow(2, Double(min(lane.failures, 5))) * 2))) }
                    catch { return }
                    lane.retry = nil; start(lane, api: api)
                }
            }
        }
    }
    private func clearFailure(_ lane: Lane) {
        guard lane.error != nil else { return }
        lane.error = nil; lane.failures = 0; lane.notice?("")
    }
}
