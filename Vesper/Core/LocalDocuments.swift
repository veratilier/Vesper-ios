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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file(api), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(api).path)
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
