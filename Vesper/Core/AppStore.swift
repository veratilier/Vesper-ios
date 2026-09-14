import SwiftUI

@MainActor final class AppStore: ObservableObject {
    weak var musicPlayer: MusicPlayer?
    @Published var documents: [String: JSONValue] = [:]
    @Published var error: String?
    @Published var loading = false
    @Published var saving = false
    @Published var connected = false
    @Published var baseURL: String = UserDefaults.standard.string(forKey: "apiURL") ?? "https://api.vesper.r-vera.com"
    @Published var historyURL: String = UserDefaults.standard.string(forKey: "historyURL") ?? "https://codex.r-vera.com/history"
    @Published var socketURL: String = UserDefaults.standard.string(forKey: "socketURL") ?? "wss://codex.r-vera.com"
    @Published var token = CredentialStore.read()
    var api: APIClient { APIClient(baseURL: baseURL, historyURL: historyURL, token: token) }
    func document(_ key: String) -> JSONValue { documents[key] ?? .null }
    func connect() async {
        do {
            _ = try APIClient.validatedURL(baseURL, path: "api/state")
            _ = try APIClient.validatedURL(historyURL, path: "conversations")
            guard let s = URL(string: socketURL), s.scheme == "wss", s.host != nil else { throw ServiceError(message: "Enter a valid WSS chat address.") }
            try CredentialStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            token = CredentialStore.read()
            UserDefaults.standard.set(baseURL, forKey: "apiURL")
            UserDefaults.standard.set(historyURL, forKey: "historyURL")
            UserDefaults.standard.set(socketURL, forKey: "socketURL")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !loading, !token.isEmpty else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await api.request("/api/state")
            guard case .object(let docs) = result["documents"] else { throw ServiceError(message: "Invalid document response.") }
            documents = docs.mapValues { $0["value"] }; connected = true
            WidgetSync.notes(document("notes"))
        } catch { self.error = error.localizedDescription; connected = false }
    }
    /// Re-read before applying an item-level mutation. Preserve unknown fields and unrelated rows.
    /// The legacy endpoint has no compare-and-swap; concurrent cross-device edits remain a server limitation.
    func mutate(_ key: String, change: (JSONValue) throws -> JSONValue) async -> Bool {
        guard !saving else { error = "Please wait for the current save."; return false }
        saving = true; defer { saving = false }
        do {
            let latest = try await api.request("/api/state?key=\(key)")
            let value = try change(latest["value"])
            _ = try await api.request("/api/state", method: "PUT", body: .object(["key": .string(key), "value": value]))
            documents[key] = value; if key == "notes" { WidgetSync.notes(value) }; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func upsert(_ key: String, item: JSONValue) async -> Bool {
        await mutate(key) { current in
            var items = current.array
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = .object(items[index].object.merging(item.object) { _, new in new })
            } else { items.insert(item, at: 0) }
            return .array(items)
        }
    }
    func remove(_ key: String, id: String) async -> Bool {
        await mutate(key) { .array($0.array.filter { $0.id != id }) }
    }
}
