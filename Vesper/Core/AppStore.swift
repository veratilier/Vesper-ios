import SwiftUI

@MainActor final class AppStore: ObservableObject {
    init() {
        // Remove the former NetEase login even when the server is offline.
        UserDefaults.standard.removeObject(forKey: "netease-uid")
        do {
            try CredentialStore.delete(account: "netease-music-u")
        } catch {
            // Keychain can reject deletion in a simulator or before unlock.
            // Keep the cleanup visible in Music without blocking startup.
            legacyMusicCleanupStatus = error.localizedDescription
        }
    }
    weak var musicPlayer: MusicPlayer?
    @Published var documents: [String: JSONValue] = [:]
    @Published var error: String?
    @Published var loading = false
    @Published var saving = false
    @Published var connected = false
    @Published var legacyMusicCleanupStatus: String?
    @Published var connectionError: String?
    @Published var baseURL: String = UserDefaults.standard.string(forKey: "apiURL") ?? "https://api.vesper.r-vera.com" {
        didSet { if oldValue != baseURL { connected = false } }
    }
    @Published var historyURL: String = UserDefaults.standard.string(forKey: "historyURL") ?? "https://codex.r-vera.com/history"
    @Published var socketURL: String = UserDefaults.standard.string(forKey: "socketURL") ?? "wss://codex.r-vera.com"
    @Published var token = CredentialStore.read() {
        didSet { if oldValue != token { connected = false } }
    }
    var api: APIClient { APIClient(baseURL: baseURL, historyURL: historyURL, token: token) }
    func document(_ key: String) -> JSONValue { documents[key] ?? .null }
    func connect() async {
        guard !loading else { return }
        connected = false
        connectionError = nil
        do {
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError(message: "Add your device token in Settings to connect.") }
            _ = try APIClient.validatedURL(baseURL, path: "api/state")
            _ = try APIClient.validatedURL(historyURL, path: "conversations")
            guard let s = URL(string: socketURL), s.scheme == "wss", s.host != nil else { throw ServiceError(message: "Enter a valid WSS chat address.") }
            try CredentialStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            token = CredentialStore.read()
            UserDefaults.standard.set(baseURL, forKey: "apiURL")
            UserDefaults.standard.set(historyURL, forKey: "historyURL")
            UserDefaults.standard.set(socketURL, forKey: "socketURL")
            await refresh()
        } catch { connectionError = error.localizedDescription }
    }
    private var documentRevision = 0
    private var cleaningLegacyMusic = false
    func refresh() async {
        guard !loading, !saving else { return }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connected = false
            connectionError = "Add your device token in Settings to connect."
            return
        }
        let requestedToken = token
        let requestedBaseURL = baseURL
        connectionError = nil
        let revision = documentRevision
        loading = true; defer { loading = false }
        do {
            let result = try await api.request("/api/state")
            guard requestedToken == token, requestedBaseURL == baseURL else { connected = false; return }
            guard case .object(let docs) = result["documents"] else { throw ServiceError(message: "Invalid document response.") }
            // A read started before a save must never replace the saved document.
            guard revision == documentRevision, !saving else { return }
            documents = docs.mapValues { $0["value"] }; connected = true
            WidgetSync.notes(document("notes"))
        } catch { connectionError = error.localizedDescription; connected = false }
    }
    private func isNetEase(_ value: JSONValue) -> Bool {
        value["id"].string.hasPrefix("netease-")
        || value["trackId"].string.hasPrefix("netease-")
        || !value["neteaseId"].string.isEmpty
        || value["source"].string == "netease"
    }
    var legacyNetEaseCount: Int {
        let tracks = ["music", "musicQueue", "musicFavorites"].reduce(0) { count, key in
            count + document(key).array.filter(isNetEase).count
        }
        let annotations = document("musicAnnotations").object.filter {
            $0.key.hasPrefix("netease-") || isNetEase($0.value)
        }.count
        let playback = isNetEase(document("musicPlayback")) || isNetEase(document("musicPlayback")["nativePlayback"]["track"]) ? 1 : 0
        let control = isNetEase(document("musicControl")) ? 1 : 0
        return tracks + annotations + playback + control
    }
    /// Called only after the user confirms removal in Music. Preserve every
    /// Apple Music song and unrelated shared music or chat document.
    func removeLegacyNetEaseMusic() async {
        guard !cleaningLegacyMusic, !token.isEmpty else { return }
        cleaningLegacyMusic = true
        defer { cleaningLegacyMusic = false }
        var success = true
        for key in ["music", "musicQueue", "musicFavorites"] {
            guard document(key).array.contains(where: isNetEase) else { continue }
            if !(await mutate(key) { current in
                .array(current.array.filter { !self.isNetEase($0) })
            }) { success = false }
        }
        let annotations = document("musicAnnotations").object
        if annotations.contains(where: { $0.key.hasPrefix("netease-") || isNetEase($0.value) }) {
            if !(await mutate("musicAnnotations") { current in
                .object(current.object.filter { !$0.key.hasPrefix("netease-") && !self.isNetEase($0.value) })
            }) { success = false }
        }
        if isNetEase(document("musicPlayback")) || isNetEase(document("musicPlayback")["nativePlayback"]["track"]) {
            if !(await mutate("musicPlayback") { _ in .object([:]) }) { success = false }
        }
        if isNetEase(document("musicControl")) {
            if !(await mutate("musicControl") { _ in .object([:]) }) { success = false }
        }
        legacyMusicCleanupStatus = success ? "Old NetEase songs were removed. Chat history was kept." : "Some old songs could not be removed. Try again when connected."
    }
    /// Re-read before applying an item-level mutation. Preserve unknown fields and unrelated rows.
    /// The legacy endpoint has no compare-and-swap; concurrent cross-device edits remain a server limitation.
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private func acquireSave() async {
        if !saving { saving = true; return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }
    private func releaseSave() {
        if saveWaiters.isEmpty { saving = false }
        else { saveWaiters.removeFirst().resume() }
    }
    func mutate(_ key: String, reportErrors: Bool = true, verifySavedValue: Bool = false, change: (JSONValue) throws -> JSONValue) async -> Bool {
        await acquireSave()
        documentRevision += 1
        defer { documentRevision += 1; releaseSave() }
        guard !Task.isCancelled else { return false }
        do {
            let latest = try await api.request("/api/state?key=\(key)")
            let value = try change(latest["value"])
            let receipt = try await api.request("/api/state", method: "PUT", body: .object(["key": .string(key), "value": value]))
            guard receipt["ok"].bool else { throw ServiceError(message: "The server did not confirm this save.") }
            if verifySavedValue {
                let saved = try await api.request("/api/state?key=\(key)")
                guard saved["value"] == value else { throw ServiceError(message: "The saved profile could not be verified. Please try changing the avatar again.") }
            }
            documents[key] = value; if key == "notes" { WidgetSync.notes(value) }; return true
        } catch { if reportErrors { self.error = error.localizedDescription }; return false }
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
