import SwiftUI
import CryptoKit

enum VesperBackend: String, CaseIterable, Identifiable {
    case vps, mac
    var id: String { rawValue }
    var title: String { self == .vps ? "VPS" : "Mac backup" }
    var credentialAccount: String { self == .vps ? "device-token" : "mac-backend-device-token" }
    func key(_ legacy: String) -> String { self == .vps ? legacy : "mac-backend." + legacy }
}
struct BackendConnection: Equatable {
    var baseURL: String
    var historyURL: String
    var socketURL: String
    static func load(_ backend: VesperBackend, defaults: UserDefaults = .standard) -> Self {
        Self(baseURL: defaults.string(forKey: backend.key("apiURL")) ?? (backend == .vps ? "https://api.vesper.r-vera.com" : "https://mac-vesper.r-vera.com"),
             historyURL: defaults.string(forKey: backend.key("historyURL")) ?? (backend == .vps ? "https://codex.r-vera.com/history" : "https://mac-vesper.r-vera.com/history"),
             socketURL: defaults.string(forKey: backend.key("socketURL")) ?? (backend == .vps ? "wss://codex.r-vera.com" : "wss://mac-vesper.r-vera.com/chat"))
    }
    func validate() throws {
        _ = try APIClient.validatedURL(baseURL, path: "api/state")
        _ = try APIClient.validatedURL(historyURL, path: "conversations")
        guard let url = URLComponents(string: socketURL), url.scheme == "wss", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ServiceError(message: "Enter a valid WSS chat address without a token in the URL.")
        }
    }
    func save(_ backend: VesperBackend, defaults: UserDefaults = .standard) {
        defaults.set(baseURL, forKey: backend.key("apiURL")); defaults.set(historyURL, forKey: backend.key("historyURL")); defaults.set(socketURL, forKey: backend.key("socketURL"))
    }
}

@MainActor final class BackendReplicaCopy: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    func copyToMac(connection: BackendConnection, token: String) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        status = "Checking both backends…"
        do {
            try connection.validate()
            let original = BackendConnection.load(.vps)
            let source = APIClient(baseURL: original.baseURL, historyURL: original.historyURL, token: try CredentialStore.load(account: VesperBackend.vps.credentialAccount))
            let target = APIClient(baseURL: connection.baseURL, historyURL: connection.historyURL, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let health = try await target.request("/api/backend")
            guard health["backend"].string == "mac" else { throw ServiceError(message: "The destination is not the Mac backend.") }
            let sourceID = SHA256.hash(data: Data((original.baseURL + "\n" + original.historyURL).utf8)).map { String(format: "%02x", $0) }.joined()
            let started = try await target.request("/api/backend/import", method: "POST", body: .object(["action": .string("begin"), "source": .string(sourceID)]))
            let job = started["jobId"].string
            guard !job.isEmpty else { throw ServiceError(message: "The Mac did not create an import session.") }
            func append(_ kind: String, _ rows: [JSONValue]) async throws {
                // Small batches stay within both services’ request bounds.
                for offset in stride(from: 0, to: rows.count, by: 10) {
                    try Task.checkCancellation()
                    _ = try await target.request("/api/backend/import", method: "POST", body: .object(["action": .string("append"), "jobId": .string(job), "kind": .string(kind), "rows": .array(Array(rows[offset..<min(offset + 10, rows.count)]))]))
                }
            }
            let listing = try await source.request("/conversations", history: true)
            guard case .array(let rooms) = listing["conversations"], rooms.count < 100 else { throw ServiceError(message: "The VPS room list is incomplete. The previous Mac copy was kept.") }
            var messageCount = 0
            for (index, room) in rooms.enumerated() {
                try Task.checkCancellation()
                guard !room.id.isEmpty else { throw ServiceError(message: "A VPS conversation is missing its ID.") }
                status = "Copying conversation \(index + 1)/\(rooms.count)…"
                try await append("room", [room])
                var cursor = "", seen: Set<String> = []
                while true {
                    var query = URLComponents(); query.queryItems = [URLQueryItem(name: "latest", value: "1"), URLQueryItem(name: "limit", value: "100")]
                    if !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
                    let page = try await source.request("/conversations/\(room.id)?" + (query.percentEncodedQuery ?? ""), history: true)
                    try ChatSession.validateHistoryRecord(page, expectedID: room.id)
                    guard case .array(let messages) = page["messages"] else { throw ServiceError(message: "Invalid source history page.") }
                    let originals = messages.map { item -> JSONValue in var item = item; item["conversationId"] = .string(room.id); return item }
                    try await append("message", originals); messageCount += messages.count
                    if !page["hasMore"].bool { break }
                    cursor = page["before"].string
                    guard !cursor.isEmpty, seen.insert(cursor).inserted else { throw ServiceError(message: "The VPS history cursor stopped advancing. Previous Mac copy was kept.") }
                }
            }
            var offset = 0
            while true {
                status = "Copying shared memories (\(offset))…"
                var query = URLComponents(); query.queryItems = [URLQueryItem(name: "path", value: "/api/memories?limit=100&offset=\(offset)&include_superseded=false")]
                let page = try await source.request("/api/shared-memory?" + (query.percentEncodedQuery ?? ""))
                guard case .array(let rows) = page["items"], case .number(let total) = page["total"] else { throw ServiceError(message: "Shared Memory did not return a complete page.") }
                try await append("memory", rows); offset += rows.count
                if offset >= Int(total) { break }
                guard !rows.isEmpty else { throw ServiceError(message: "Shared Memory pagination was incomplete.") }
            }
            let result = try await target.request("/api/backend/import", method: "POST", body: .object(["action": .string("commit"), "jobId": .string(job)]))
            guard result["ok"].bool else { throw ServiceError(message: "Mac did not confirm the copy.") }
            status = "Copied \(messageCount) messages and \(offset) memories. Originals stay on VPS; Mac can retrieve this copy."
        } catch { status = "Copy not completed. Previous copy kept. " + error.localizedDescription }
    }
}

@MainActor final class AppStore: ObservableObject {
    private let loadState: (APIClient) async throws -> JSONValue
    private let retryDelay: () async throws -> Void
    private let disk: LocalDocumentDisk
    private let requestDocument: (APIClient, String, String, JSONValue?) async throws -> JSONValue
    init(loadState: @escaping (APIClient) async throws -> JSONValue = { try await $0.request("/api/state") },
         retryDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
         disk: LocalDocumentDisk = LocalDocumentDisk(),
         requestDocument: @escaping (APIClient, String, String, JSONValue?) async throws -> JSONValue = { try await $0.request($1, method: $2, body: $3) }) {
        self.loadState = loadState
        self.retryDelay = retryDelay
        self.disk = disk
        self.requestDocument = requestDocument
        let saved = BackendConnection.load(activeBackend)
        baseURL = saved.baseURL; historyURL = saved.historyURL; socketURL = saved.socketURL
        do { token = try CredentialStore.load(account: activeBackend.credentialAccount) } catch { connectionError = error.localizedDescription }
        cachedProfile = ProfileDisplayCache.load(baseURL: baseURL, token: token)
        restoreLocalDocuments()
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
    @Published private var cachedProfile: JSONValue = .null
    @Published var error: String?
    @Published var loading = false
    @Published var saving = false
    @Published var connected = false
    @Published private(set) var hasLocalData = false
    @Published private(set) var syncing = false
    @Published private(set) var pendingDocuments: [String: PendingDocument] = [:]
    @Published private(set) var syncError: String?
    @Published private(set) var conflictingDocuments: Set<String> = []
    @Published private(set) var lastSyncedAt: Date?
    var canEnter: Bool { connected || (hasLocalData && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private var syncTask: Task<Void, Never>?
    private var identityGeneration = UUID()
    @Published var legacyMusicCleanupStatus: String?
    @Published var connectionError: String?
    @Published private(set) var activeBackend: VesperBackend = VesperBackend(rawValue: UserDefaults.standard.string(forKey: "vesper.activeBackend") ?? "") ?? .vps
    @Published var baseURL: String = UserDefaults.standard.string(forKey: "apiURL") ?? "https://api.vesper.r-vera.com" {
        didSet { if oldValue != baseURL { restoreLocalDocuments() } }
    }
    @Published var historyURL: String = UserDefaults.standard.string(forKey: "historyURL") ?? "https://codex.r-vera.com/history"
    @Published var socketURL: String = UserDefaults.standard.string(forKey: "socketURL") ?? "wss://codex.r-vera.com"
    @Published var token = "" {
        didSet { if oldValue != token { restoreLocalDocuments() } }
    }
    var api: APIClient { APIClient(baseURL: baseURL, historyURL: historyURL, token: token) }
    func document(_ key: String) -> JSONValue { documents[key] ?? (key == "profile" ? cachedProfile : .null) }
    private func restoreLocalDocuments() {
        identityGeneration = UUID()
        syncTask?.cancel(); syncTask = nil; syncing = false
        connected = false; hasLocalData = false
        documents = [:]; pendingDocuments = [:]; lastSyncedAt = nil; syncError = nil; conflictingDocuments = []
        cachedProfile = ProfileDisplayCache.load(baseURL: baseURL, token: token)
        do {
            if let snapshot = try disk.load(api) {
                documents = snapshot.documents; pendingDocuments = snapshot.pending
                lastSyncedAt = snapshot.lastSync; hasLocalData = true
            }
        } catch { syncError = "Local data could not be read. Reconnect to restore the cloud copy." }
    }
    private func persist(_ values: [String: JSONValue], pending: [String: PendingDocument], syncedAt: Date?) throws {
        try disk.save(LocalDocumentSnapshot(documents: values, pending: pending, lastSync: syncedAt), api: api)
    }
    /// User-authored collections can be saved offline. Commands, credentials and
    /// verified room-pointer changes still require a confirmed server response.
    static let localDocumentKeys: Set<String> = ["notes", "todos", "anniversaries", "diary", "favorites", "readingRoom", "music", "musicFavorites", "musicPlaylists", "musicAnnotations"]
    func scheduleSync() {
        guard syncTask == nil, !pendingDocuments.isEmpty else { return }
        let generation = identityGeneration
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.syncPendingDocuments()
            if self.identityGeneration == generation { self.syncTask = nil }
        }
    }
    func syncPendingDocuments() async {
        guard !syncing, !saving, !pendingDocuments.isEmpty, !token.isEmpty else { return }
        let generation = identityGeneration, client = api
        syncing = true; syncError = nil
        defer { if generation == identityGeneration { syncing = false } }
        for key in pendingDocuments.keys.sorted() {
            guard let selected = pendingDocuments[key], !Task.isCancelled else { continue }
            do {
                let latest = try await requestDocument(client, "/api/state?key=\(key)", "GET", nil)
                guard generation == identityGeneration, !Task.isCancelled else { return }
                let merged = try DocumentMerge.apply(base: selected.base, local: selected.value, remote: latest["value"]) ?? .null
                if merged != latest["value"] {
                    let receipt = try await requestDocument(client, "/api/state", "PUT", .object(["key": .string(key), "value": merged]))
                    guard receipt["ok"].bool else { throw ServiceError(message: "The server did not confirm synchronization.") }
                }
                guard generation == identityGeneration, !Task.isCancelled else { return }
                var pending = pendingDocuments, values = documents
                if let newer = pending[key], newer.id != selected.id {
                    // Edits made while the PUT was in flight remain queued and
                    // are rebased onto its acknowledged result, not discarded.
                    let rebased = try DocumentMerge.apply(base: selected.value, local: newer.value, remote: merged, preferLocal: true) ?? .null
                    pending[key] = PendingDocument(base: merged, value: rebased); values[key] = rebased
                } else { pending.removeValue(forKey: key); values[key] = merged }
                let now = Date()
                try persist(values, pending: pending, syncedAt: now)
                documentRevision += 1
                documents = values; pendingDocuments = pending; lastSyncedAt = now; hasLocalData = true
                conflictingDocuments.remove(key)
                if key == "notes" { WidgetSync.notes(document(key)) }
            } catch {
                guard generation == identityGeneration, !Task.isCancelled else { return }
                if error is DocumentMerge.Conflict { conflictingDocuments.insert(key) }
                syncError = error is DocumentMerge.Conflict ? "\(key.capitalized): \(error.localizedDescription)" : "Saved on this device. Cloud sync will retry when available."
            }
        }
    }
    func resolvePendingDocument(_ key: String, keepLocal: Bool) async {
        guard !syncing, let selected = pendingDocuments[key] else { return }
        let generation = identityGeneration, client = api
        do {
            let latest = try await requestDocument(client, "/api/state?key=\(key)", "GET", nil)
            guard generation == identityGeneration, pendingDocuments[key]?.id == selected.id else { return }
            var pending = pendingDocuments, values = documents
            if keepLocal {
                let merged = try DocumentMerge.apply(base: selected.base, local: selected.value, remote: latest["value"], preferLocal: true) ?? .null
                pending[key] = PendingDocument(base: latest["value"], value: merged); values[key] = merged
            } else { pending.removeValue(forKey: key); values[key] = latest["value"] }
            try persist(values, pending: pending, syncedAt: lastSyncedAt)
            documentRevision += 1; pendingDocuments = pending; documents = values; syncError = nil; conflictingDocuments.remove(key)
            scheduleSync()
        } catch { if generation == identityGeneration { syncError = error.localizedDescription } }
    }
    private func rememberProfile(_ value: JSONValue) {
        cachedProfile = ProfileDisplayCache.displayFields(value)
        ProfileDisplayCache.save(cachedProfile, baseURL: baseURL, token: token)
    }
    func connect() async {
        guard !loading else { return }
        connected = false
        connectionError = nil
        do {
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError(message: "Add your device token in Settings to connect.") }
            let connection = BackendConnection(baseURL: baseURL, historyURL: historyURL, socketURL: socketURL)
            try connection.validate()
            try CredentialStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: activeBackend.credentialAccount)
            token = try CredentialStore.load(account: activeBackend.credentialAccount)
            connection.save(activeBackend)
            await refresh()
        } catch { connectionError = error.localizedDescription }
    }
    /// Connection editor owns drafts; failed validation never replaces the active backend.
    func activateBackend(_ backend: VesperBackend, connection: BackendConnection, credential: String, canSwitch: () -> Bool = { true }) async -> Bool {
        guard !loading, !saving, !syncing, canSwitch() else { connectionError = "Finish the current reply, call or save before switching."; return false }
        let credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try connection.validate()
            guard !credential.isEmpty else { throw ServiceError(message: "Enter this backend’s own device token.") }
            let candidate = APIClient(baseURL: connection.baseURL, historyURL: connection.historyURL, token: credential)
            loading = true
            defer { loading = false }
            let state = try await loadState(candidate)
            guard case .object(let docs) = state["documents"] else { throw ServiceError(message: "Invalid backend response.") }
            if backend == .mac {
                guard state["backend"]["backend"].string == "mac", !state["backend"]["backendId"].string.isEmpty else { throw ServiceError(message: "This address did not identify itself as the Mac backend.") }
                let history = try await candidate.request("/health", history: true)
                guard history["backendId"] == state["backend"]["backendId"] else { throw ServiceError(message: "The history address belongs to a different backend.") }
            }
            guard canSwitch(), !saving, !syncing else { throw ServiceError(message: "Finish the current reply or save before switching.") }
            try Task.checkCancellation()
            try CredentialStore.save(credential, account: backend.credentialAccount)
            connection.save(backend)
            NotificationCenter.default.post(name: .init("VesperBackendWillChange"), object: nil)
            activeBackend = backend
            baseURL = connection.baseURL; historyURL = connection.historyURL; socketURL = connection.socketURL; token = credential
            restoreLocalDocuments()
            UserDefaults.standard.set(backend.rawValue, forKey: "vesper.activeBackend")
            // The candidate was already authenticated. Apply that snapshot in its own
            // local scope rather than adding a second network failure after activation.
            connected = true; connectionError = nil
            applyRemoteDocuments(docs)
            return true
        } catch { connectionError = error.localizedDescription; return false }
    }
    private func applyRemoteDocuments(_ docs: [String: JSONValue]) {
        var values = docs.mapValues { $0["value"] }
        for (key, pending) in pendingDocuments { values[key] = pending.value }
        documents = values
        let now = Date()
        do { try persist(values, pending: pendingDocuments, syncedAt: now); hasLocalData = true; lastSyncedAt = now }
        catch { syncError = "Cloud data loaded, but the local copy could not be saved." }
        rememberProfile(documents["profile"] ?? .null)
        WidgetSync.notes(document("notes"))
        scheduleSync()
    }
    private var documentRevision = 0
    private var cleaningLegacyMusic = false
    func refresh(retryTransientFailures: Bool = false, minimumInterval: TimeInterval = 0) async {
        scheduleSync()
        if connected, let lastSyncedAt, Date().timeIntervalSince(lastSyncedAt) < minimumInterval, pendingDocuments.isEmpty { return }
        // A new foreground task can start before the cancelled request has unwound.
        if retryTransientFailures {
            let wasLoading = loading
            while loading || saving {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            if wasLoading && connected { return }
        }
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
        let client = api
        let attempts = retryTransientFailures ? 3 : 1
        for attempt in 0..<attempts {
            do {
                try Task.checkCancellation()
                let result = try await loadState(client)
                try Task.checkCancellation()
                guard requestedToken == token, requestedBaseURL == baseURL else { return }
                guard case .object(let docs) = result["documents"] else { throw ServiceError(message: "Invalid document response.") }
                // Authentication succeeded even if a concurrent save makes this snapshot stale.
                connected = true
                // A read started before a save must never replace the saved document.
                guard revision == documentRevision, !saving else { return }
                applyRemoteDocuments(docs)
                return
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      (error as? URLError)?.code != .cancelled,
                      requestedToken == token, requestedBaseURL == baseURL else { return }
                if attempt + 1 < attempts && Self.isTemporaryConnectionFailure(error) {
                    do { try await retryDelay() } catch { return }
                    guard requestedToken == token, requestedBaseURL == baseURL else { return }
                    continue
                }
                connectionError = error.localizedDescription; connected = false
                return
            }
        }
    }
    private static func isTemporaryConnectionFailure(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .notConnectedToInternet].contains(error.code)
        }
        return [408, 429, 500, 502, 503, 504].contains((error as? ServiceError)?.statusCode ?? 0)
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
        if saveWaiters.isEmpty { saving = false; scheduleSync() }
        else { saveWaiters.removeFirst().resume() }
    }
    func mutate(_ key: String, reportErrors: Bool = true, verifySavedValue: Bool = false, change: (JSONValue) throws -> JSONValue) async -> Bool {
        let invocationGeneration = identityGeneration
        if verifySavedValue, pendingDocuments[key] != nil {
            if let syncTask { await syncTask.value }
            guard invocationGeneration == identityGeneration else { return false }
            await syncPendingDocuments()
            guard invocationGeneration == identityGeneration else { return false }
            guard pendingDocuments[key] == nil else {
                if reportErrors { error = "Your local changes are saved. Finish cloud sync before requesting a verified save." }
                return false
            }
        }
        if Self.localDocumentKeys.contains(key), !verifySavedValue, hasLocalData {
            do {
                let value = try change(document(key))
                guard value != document(key) else { return true }
                var pending = pendingDocuments, values = documents
                pending[key] = PendingDocument(base: pending[key]?.base ?? document(key), value: value)
                values[key] = value
                try persist(values, pending: pending, syncedAt: lastSyncedAt)
                documentRevision += 1; documents = values; pendingDocuments = pending
                if key == "notes" { WidgetSync.notes(value) }
                scheduleSync()
                return true
            } catch { if reportErrors { self.error = error.localizedDescription }; return false }
        }
        await acquireSave()
        documentRevision += 1
        defer { documentRevision += 1; releaseSave() }
        guard !Task.isCancelled, invocationGeneration == identityGeneration else { return false }
        let client = api, generation = identityGeneration
        do {
            let latest = try await requestDocument(client, "/api/state?key=\(key)", "GET", nil)
            guard generation == identityGeneration else { return false }
            let value = try change(latest["value"])
            let receipt = try await requestDocument(client, "/api/state", "PUT", .object(["key": .string(key), "value": value]))
            guard receipt["ok"].bool else { throw ServiceError(message: "The server did not confirm this save.") }
            if verifySavedValue {
                let saved = try await requestDocument(client, "/api/state?key=\(key)", "GET", nil)
                guard saved["value"] == value else { throw ServiceError(message: "The saved profile could not be verified. Please try again.") }
            }
            guard generation == identityGeneration else { return false }
            documents[key] = pendingDocuments[key]?.value ?? value
            do { try persist(documents, pending: pendingDocuments, syncedAt: lastSyncedAt); hasLocalData = true }
            catch { syncError = "Saved in the cloud, but the local copy could not be saved." }
            if key == "profile" { rememberProfile(value) }; if key == "notes" { WidgetSync.notes(value) }; return true
        } catch { if reportErrors, generation == identityGeneration { self.error = error.localizedDescription }; return false }
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

private enum ProfileDisplayCache {
    static func displayFields(_ profile: JSONValue) -> JSONValue {
        guard case .object = profile else { return .null }
        return .object(Dictionary(uniqueKeysWithValues: ["userName", "agentName", "userAvatar", "agentAvatar"].compactMap { key in
            let value = profile[key]
            return value.string.isEmpty ? nil : (key, value)
        }))
    }
    private static func file(baseURL: String, token: String) -> URL? {
        guard !token.isEmpty, let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identity = SHA256.hash(data: Data((baseURL + "\n" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("profile-display-\(identity).json")
    }
    static func load(baseURL: String, token: String) -> JSONValue {
        guard let url = file(baseURL: baseURL, token: token), let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return displayFields(profile)
    }
    static func save(_ profile: JSONValue, baseURL: String, token: String) {
        guard let url = file(baseURL: baseURL, token: token) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(profile)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch { /* Cache failure must never block a confirmed server save. */ }
    }
}
