import Foundation
import Combine
import CryptoKit

enum ChatReplyMode: String, CaseIterable {
    case immediate, collected
    var title: String { self == .immediate ? "即时回复" : "攒好再回复" }
}

struct ChatQueuedMessage: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt = ISO8601DateFormatter().string(from: Date())
    var text: String
    var images: [Data] = []
    var files: [ChatFile] = []
    var music: JSONValue?
    var sticker: JSONValue?
    var location: JSONValue?
    var replyTo: JSONValue?

    var summary: String {
        if !text.isEmpty { return text }
        if !images.isEmpty { return "图片 × \(images.count)" }
        if !files.isEmpty { return files.map(\.name).joined(separator: "、") }
        if let music { return "分享音乐 · " + music["title"].string }
        if let sticker { return "表情 · " + sticker["name"].string }
        return "分享位置"
    }

    func message(conversationID: String, attachments: [JSONValue] = []) -> JSONValue {
        var value: JSONValue = .object(["id": .string(id), "conversationId": .string(conversationID),
            "role": .string("user"), "content": .string(text), "createdAt": .string(createdAt),
            "metadata": .object(["attachments": .array(attachments)])])
        if let music { value["metadata"]["musicCard"] = music }
        if let sticker { value["metadata"]["sticker"] = sticker }
        if let location { value["metadata"]["locationCard"] = location }
        if let replyTo { value["metadata"]["replyTo"] = replyTo }
        return value
    }
}

/// Unsubmitted messages are local drafts, partitioned by service, account and chat.
enum ChatQueuedStore {
    static func url(api: APIClient, conversationID: String) throws -> URL {
        guard !api.token.isEmpty else { throw ServiceError(message: "请先连接聊天服务。") }
        let identity = [api.baseURL, api.historyURL, api.token, conversationID].joined(separator: "\n")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatQueuedMessages").appendingPathComponent(key + ".json")
    }
    static func load(api: APIClient, conversationID: String) throws -> [ChatQueuedMessage] {
        let file = try url(api: api, conversationID: conversationID)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ChatQueuedMessage].self, from: Data(contentsOf: file))
    }
    static func save(_ messages: [ChatQueuedMessage], api: APIClient, conversationID: String) throws {
        let file = try url(api: api, conversationID: conversationID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(messages).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

// Text changes are observed only by the input controls, not the transcript.
final class ChatDraftText: ObservableObject {
    @Published var value = ""
}

final class ChatComposer: ObservableObject {
    let text = ChatDraftText()
    var draft: String {
        get { text.value }
        set { text.value = newValue }
    }
    @Published var images: [Data] = []
    @Published var files: [ChatFile] = []
    @Published var pendingMusic: JSONValue?
    @Published var pendingSticker: JSONValue?
    @Published var replyTo: JSONValue?

    private struct Draft {
        var text = ""
        var images: [Data] = []
        var files: [ChatFile] = []
        var music: JSONValue?
        var sticker: JSONValue?
        var replyTo: JSONValue?
    }
    private var saved: [String: Draft] = [:]

    func switchConversation(from: String, to: String) {
        guard from != to else { return }
        saved[from] = Draft(text: draft, images: images, files: files, music: pendingMusic, sticker: pendingSticker, replyTo: replyTo)
        let next = saved[to] ?? Draft()
        draft = next.text
        images = next.images
        files = next.files
        pendingMusic = next.music
        pendingSticker = next.sticker
        replyTo = next.replyTo
    }
}


enum ChatStickerInput {
    static func context(text: String, sticker: JSONValue) -> String {
        let description = "Shared sticker: " + sticker["name"].string + " " + sticker["description"].string + " (assetId: " + sticker["assetId"].string + ")"
        return (text.isEmpty ? "" : text + "\n") + description
    }
}
