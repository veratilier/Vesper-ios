import Foundation

@MainActor enum ChatFavorites {
    static func existing(_ messageID: String, conversationID: String, in store: AppStore) -> JSONValue? {
        store.document("favorites").array.first {
            $0["messageId"].string == messageID && $0["conversationId"].string == conversationID
        }
    }

    @discardableResult
    static func save(_ message: JSONValue, conversationID: String, title: String, in store: AppStore) async -> Bool {
        guard !message.id.isEmpty, !conversationID.isEmpty else { return false }
        let item: JSONValue = .object([
            "id": .string(UUID().uuidString), "folderId": .string("default"),
            "messageId": .string(message.id), "conversationId": .string(conversationID),
            "conversationTitle": .string(title), "content": message["content"],
            "role": message["role"], "createdAt": message["createdAt"], "metadata": message["metadata"]
        ])
        return await store.mutate("favorites") { current in
            var items = current.array
            if !items.contains(where: { $0["messageId"].string == message.id && $0["conversationId"].string == conversationID }) {
                items.insert(item, at: 0)
            }
            return .array(items)
        }
    }

    @discardableResult
    static func removeCopies(conversationID: String, messageID: String? = nil, in store: AppStore) async -> Bool {
        await store.mutate("favorites", reportErrors: false) { current in
            .array(current.array.filter { item in
                guard item["conversationId"].string == conversationID else { return true }
                return messageID.map { id in
                item["messageId"].string != id && !item["metadata"]["sharedMedia"].array.contains(where: { $0.id == id })
            } ?? false
            })
        }
    }
}
