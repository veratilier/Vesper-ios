import Foundation

/// One place for chat identity, history reconciliation and presentation order.
/// The history service owns durable messages; live Codex items fill gaps until
/// they are persisted. Neither paging nor reconnecting may discard older rows.
enum ChatTranscript {
    static func isDeleted(_ message: JSONValue, tombstones: [JSONValue]) -> Bool {
        tombstones.contains { tombstone in
            let ids = [tombstone["messageId"].string, tombstone["itemId"].string,
                       tombstone["stableId"].string].filter { !$0.isEmpty }
            return ids.contains(message.id) || ids.contains(message["metadata"]["itemId"].string)
        }
    }

    static func ordered(_ messages: [JSONValue]) -> [JSONValue] {
        // Records without a trustworthy time retain their original positions;
        // never invent a date just to push them to the start or end.
        let timestamps = messages.map { UserHistoryRecovery.parsedTime($0["createdAt"].string) }
        let dated = messages.enumerated().compactMap { index, message -> (Int, JSONValue, Date)? in
            guard let time = timestamps[index] else { return nil }
            return (index, message, time)
        }.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 < rhs.2
        }
        var result = messages
        var next = 0
        for index in messages.indices where timestamps[index] != nil {
            result[index] = dated[next].1
            next += 1
        }
        return result
    }

    static func merge(_ existing: [JSONValue], incoming: [JSONValue], tombstones: [JSONValue]) -> [JSONValue] {
        var result = existing.filter { !isDeleted($0, tombstones: tombstones) }
        var positions: [String: Int] = [:]
        for index in result.indices where !result[index].id.isEmpty { positions[result[index].id] = index }
        for message in incoming where !isDeleted(message, tombstones: tombstones) {
            if let index = positions[message.id], !message.id.isEmpty {
                // A locally pending row is not proof of acceptance. A durable
                // delivered row is, and must replace the pending copy.
                if message["status"].string == "delivered" { result[index] = message }
            } else {
                if !message.id.isEmpty { positions[message.id] = result.count }
                result.append(message)
            }
        }
        return ordered(result)
    }
}
