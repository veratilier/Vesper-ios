import Foundation

/// One place for chat identity, history reconciliation and presentation order.
/// The history service owns durable messages; live Codex items fill gaps until
/// they are persisted. Neither paging nor reconnecting may discard older rows.
enum ChatTranscript {
    private static func parsedTime(_ value: JSONValue) -> Date? {
        if case .number(let seconds) = value, seconds.isFinite {
            let time = seconds > 10_000_000_000 ? seconds / 1000 : seconds
            return (946_684_800...4_102_444_800).contains(time) ? Date(timeIntervalSince1970: time) : nil
        }
        return UserHistoryRecovery.parsedTime(value.string)
    }

    private static func messageTime(_ message: JSONValue) -> Date? {
        let created = parsedTime(message["createdAt"])
        let meta = message["metadata"]
        let wake = meta["wake"]
        let isWake = wake != .null || !meta["wakeRunId"].string.isEmpty || meta["source"].string == "automation"
        guard isWake else { return created }
        // A wake reply may be inserted into history after the run finishes.
        // Prefer its recorded delivery/completion time over the insertion time.
        for value in [wake["deliveredAt"], wake["completedAt"], wake["createdAt"],
                      meta["deliveredAt"], meta["completedAt"], meta["sentAt"],
                      wake["startedAt"], meta["startedAt"]] {
            if let time = parsedTime(value) { return time }
        }
        // The wake runner's scheduled jobs use auto-<unix seconds> as their
        // durable run ID. Older history lacks a separate run timestamp, so
        // place those replies at the wake's scheduled time, not when a late
        // run happened to finish and write its message to history.
        let runID = meta["wakeRunId"].string
        if runID.hasPrefix("auto-"), let seconds = Double(runID.dropFirst(5)),
           let scheduled = parsedTime(.number(seconds)) { return scheduled }
        return created
    }

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
        let timestamps = messages.map(messageTime)
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
