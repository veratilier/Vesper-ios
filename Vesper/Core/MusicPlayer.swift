import Foundation
import MusicKit
import SwiftUI

// The backend stores song metadata for chat cards and shared playback. MusicKit
// keeps the actual songs and authorization on this device; no stream URL or
// Apple Music credential is ever sent to Vesper's server.
@MainActor final class MusicPlayer: ObservableObject {
    @Published var tracks: [JSONValue] = []
    @Published var track: JSONValue = .null
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var mode = "order"
    @Published var resolving = false
    private let native = ApplicationMusicPlayer.shared
    private var songs: [String: Song] = [:]
    private var library: [JSONValue] = []
    private weak var store: AppStore?
    private var timer: Timer?
    private var selection = UUID()
    private var lastControlID = ""
    private var pollingControl = false
    private var lastSyncAt = Date.distantPast
    private var lastSyncTrack = ""
    private var lastSyncPlaying = false
    private var syncTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?

    func configure(_ store: AppStore) {
        self.store = store
        store.musicPlayer = self
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.synchronize() }
            }
        }
    }

    func register(_ values: [Song]) {
        for song in values { songs[song.id.rawValue] = song }
    }

    func updateLibrary(_ values: [JSONValue]) { library = values }
    func setQueue(_ values: [JSONValue], append: Bool = false) {
        var seen = Set<String>()
        tracks = (append ? tracks + values : values).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        if !tracks.contains(where: { $0.id == track.id }) {
            pause()
            track = tracks.first ?? .null
            position = 0
            duration = track["duration"].number
            synchronize()
        }
    }
    func remove(_ id: String) { setQueue(tracks.filter { $0.id != id }) }
    func cycleMode() {
        let modes = ["order", "repeat", "single", "random"]
        mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
    }

    func select(_ value: JSONValue) {
        playTask?.cancel()
        selection = UUID()
        let requested = selection
        native.pause()
        track = value
        if !tracks.contains(where: { $0.id == value.id }) { tracks.append(value) }
        playing = false
        position = 0
        duration = value["duration"].number
        error = nil
        synchronize()
        guard value["source"].string == "appleMusic",
              let id = value["appleMusicId"].string.nonEmpty else {
            error = MusicError.unavailable.localizedDescription
            return
        }
        resolving = true
        playTask = Task {
            do {
                let authorized = await MusicAuthorization.request()
                guard authorized == .authorized else { throw MusicError.permission }
                let subscription = try await MusicSubscription.current
                guard subscription.canPlayCatalogContent else { throw MusicError.subscription }
                let selected = try await song(for: id)
                try Task.checkCancellation()
                guard selection == requested else { return }
                // Use the selected song as a native MusicKit queue. Keep the
                // visible Vesper queue for previous/next and chat controls.
                native.queue = ApplicationMusicPlayer.Queue(for: [selected])
                try await native.play()
                guard selection == requested else { native.pause(); return }
                resolving = false
                duration = selected.duration ?? value["duration"].number
                synchronize()
            } catch {
                if !Task.isCancelled, selection == requested {
                    resolving = false
                    self.error = error.localizedDescription
                    synchronize()
                }
            }
        }
    }
    private func song(for id: String) async throws -> Song {
        if let song = songs[id] { return song }
        // Shared cards survive app restarts. Re-fetch catalog songs on demand.
        let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
        guard let song = try await request.response().items.first else { throw MusicError.unavailable }
        songs[id] = song
        return song
    }
    func start(_ value: JSONValue) { select(value) }
    func play() {
        guard !resolving else { return }
        guard track != .null else { return }
        guard track["source"].string == "appleMusic" else { select(track); return }
        if native.queue.entries.isEmpty { select(track); return }
        playTask = Task {
            do { try await native.play(); synchronize() }
            catch { self.error = error.localizedDescription; synchronize() }
        }
    }
    func pause() {
        selection = UUID()
        playTask?.cancel()
        resolving = false
        native.pause()
        synchronize()
    }
    func toggle() { (resolving || playing) ? pause() : play() }
    func next(_ delta: Int) {
        guard !tracks.isEmpty else { return }
        if mode == "random", tracks.count > 1,
           let choice = tracks.filter({ $0.id != track.id }).randomElement() {
            select(choice)
            return
        }
        let index = tracks.firstIndex { $0.id == track.id } ?? 0
        select(tracks[(index + delta + tracks.count) % tracks.count])
    }
    func seek(_ value: Double) {
        native.playbackTime = value
        synchronize()
    }
    func synchronize() {
        playing = native.state.playbackStatus == .playing
        let elapsed = native.playbackTime
        position = track["source"].string == "appleMusic" && elapsed.isFinite ? max(0, elapsed) : 0
        syncPlayback()
    }
    var liveContext: JSONValue {
        .object(["track": .object(["id": track["id"], "title": track["title"],
                                    "artist": track["artist"], "album": track["album"]]),
                 "playing": .bool(playing), "resolving": .bool(resolving),
                 "positionSeconds": .number(position), "durationSeconds": .number(duration),
                 "observedAt": .string(isoNow()), "audioIncluded": .bool(false)])
    }
    func pollControl() async {
        guard !pollingControl, let store, !store.token.isEmpty else { return }
        pollingControl = true
        defer { pollingControl = false }
        do {
            let result = try await store.api.request("/api/state?key=musicControl")
            let command = result["value"]
            guard !Task.isCancelled, !command.id.isEmpty, command["processedAt"].string.isEmpty else { return }
            if command.id != lastControlID {
                switch command["action"].string {
                case "play": play()
                case "pause": pause()
                case "next": guard !tracks.isEmpty else { return }; next(1)
                case "previous": guard !tracks.isEmpty else { return }; next(-1)
                case "play_track":
                    let id = command["trackId"].string
                    guard let song = (tracks + library).first(where: { $0.id == id || $0["appleMusicId"].string == id }) else { return }
                    select(song)
                default: return
                }
                lastControlID = command.id
            }
            _ = await store.mutate("musicControl", reportErrors: false) { current in
                guard current.id == command.id else { return current }
                var updated = current
                updated["processedAt"] = .string(isoNow())
                return updated
            }
        } catch { /* A later foreground refresh can retry. */ }
    }
    private func syncPlayback() {
        guard let store, !store.token.isEmpty, !store.saving, syncTask == nil else { return }
        guard lastSyncTrack != track.id || lastSyncPlaying != playing || Date().timeIntervalSince(lastSyncAt) >= 15 else { return }
        let value = liveContext, currentTrack = track, at = Date()
        syncTask = Task {
            defer { syncTask = nil }
            let saved = await store.mutate("musicPlayback", reportErrors: false) { current in
                var next = current
                next["trackId"] = currentTrack["id"]
                next["playing"] = value["playing"]
                next["positionSeconds"] = value["positionSeconds"]
                next["durationSeconds"] = value["durationSeconds"]
                next["updatedAt"] = value["observedAt"]
                next["nativePlayback"] = value
                return next
            }
            if saved { lastSyncAt = at; lastSyncTrack = currentTrack.id; lastSyncPlaying = value["playing"].bool }
        }
    }
    private enum MusicError: LocalizedError {
        case unavailable, permission, subscription
        var errorDescription: String? {
            switch self {
            case .unavailable: return "This song is not available in Apple Music on this device."
            case .permission: return "Allow Vesper access to Apple Music in Settings to play songs."
            case .subscription: return "An Apple Music subscription is required to play catalog songs."
            }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

@MainActor final class MusicCatalog: ObservableObject {
    @Published var playlists: [JSONValue] = []
    @Published var songs: [JSONValue] = []
    @Published var collection: JSONValue = .null
    @Published var busy = false
    @Published var message = ""
    @Published var connected = MusicAuthorization.currentStatus == .authorized
    private var playlistItems: [String: Playlist] = [:]

    static func metadata(_ song: Song) -> JSONValue {
        let id = song.id.rawValue
        return .object(["id": .string("apple-" + id),
                        "appleMusicId": .string(id),
                        "source": .string("appleMusic"),
                        "title": .string(song.title),
                        "artist": .string(song.artistName),
                        "album": .string(song.albumTitle ?? ""),
                        "cover": .string(song.artwork?.url(width: 500, height: 500)?.absoluteString ?? ""),
                        "appleMusicURL": .string(song.url?.absoluteString ?? ""),
                        "duration": .number(song.duration ?? 0)])
    }
    func connect(player: MusicPlayer) async {
        guard !busy else { return }
        busy = true; message = ""
        defer { busy = false }
        guard await MusicAuthorization.request() == .authorized else {
            connected = false; message = "Allow access to Apple Music to see your library."; return
        }
        connected = true
        await refresh(player: player)
    }
    func refresh(player: MusicPlayer) async {
        guard connected else { return }
        do {
            var songsRequest = MusicLibraryRequest<Song>()
            songsRequest.limit = 100
            let songs = try await songsRequest.response().items
            player.register(Array(songs))
            self.songs = songs.map(Self.metadata)
            var playlistRequest = MusicLibraryRequest<Playlist>()
            playlistRequest.limit = 100
            let items = try await playlistRequest.response().items
            playlistItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id.rawValue, $0) })
            playlists = items.map { .object(["id": .string($0.id.rawValue),
                                            "name": .string($0.name),
                                            "cover": .string($0.artwork?.url(width: 200, height: 200)?.absoluteString ?? "")]) }
        } catch { message = error.localizedDescription }
    }
    func mySongs(player: MusicPlayer) async {
        await refresh(player: player)
        collection = .object(["title": .string("My songs"), "tracks": .array(songs)])
    }
    func playlist(_ id: String, player: MusicPlayer) async {
        guard !busy, let playlist = playlistItems[id] else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            let detailed = try await playlist.with([.tracks])
            let songs = detailed.tracks?.compactMap { item -> Song? in
                if case .song(let song) = item { return song }
                return nil
            } ?? []
            player.register(songs)
            collection = .object(["title": .string(playlist.name),
                                  "tracks": .array(songs.map(Self.metadata))])
        } catch { message = error.localizedDescription }
    }
    func search(_ term: String, player: MusicPlayer) async {
        guard !busy, !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 30
            let songs = try await request.response().songs
            player.register(Array(songs))
            collection = .object(["title": .string("Search results"),
                                  "tracks": .array(songs.map(Self.metadata))])
        } catch { message = error.localizedDescription }
    }
    func prepare(_ values: [JSONValue], store: AppStore, player: MusicPlayer,
                 append: Bool = false, autoplay: Bool = true) async {
        guard !values.isEmpty else { return }
        player.setQueue(values, append: append)
        let saved = await store.mutate("music") { current in
            // The app cleanup removes old NetEase tracks; keep only songs
            // explicitly selected from Apple Music in the shared library.
            var merged = current.array
            for value in values {
                if let index = merged.firstIndex(where: { $0.id == value.id }) { merged[index] = value }
                else { merged.append(value) }
            }
            return .array(merged)
        }
        message = saved ? "Added \(values.count) songs" : "Queue updated on this phone; library sync failed."
        if autoplay, let first = values.first { player.select(first) }
    }
}
