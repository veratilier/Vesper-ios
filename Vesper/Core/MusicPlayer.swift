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
    @Published private(set) var currentArtwork: MusicKit.Artwork?
    @Published private(set) var resolvedArtwork: [String: MusicKit.Artwork] = [:]
    @Published private(set) var lyrics: [JSONValue] = []
    @Published private(set) var lyricsLoading = false
    @Published private(set) var lyricSource: String?
    private let native = ApplicationMusicPlayer.shared
    private var loadedTrackID = ""
    private var queueTracks: [String: JSONValue] = [:]
    private var songs: [String: Song] = [:]
    private var artworkLookups = Set<String>()
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
    private var lyricTask: Task<Void, Never>?
    private var lyricCache: [String: [JSONValue]] = [:]

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

    func artwork(for value: JSONValue) -> MusicKit.Artwork? {
        let id = value["appleMusicId"].string
        return songs[id]?.artwork ?? resolvedArtwork[id]
    }

    func ensureArtwork(for value: JSONValue) async {
        guard let id = value["appleMusicId"].string.nonEmpty,
              artwork(for: value) == nil,
              artworkLookups.insert(id).inserted else { return }
        guard let song = try? await song(for: id) else { return }
        let detail = try? await song.with([.albums])
        guard let image = detail?.albums?.first?.artwork else { return }
        resolvedArtwork[id] = image
        if track["appleMusicId"].string == id { currentArtwork = image }
    }

    func updateLibrary(_ values: [JSONValue]) { library = values }
    func setQueue(_ values: [JSONValue], append: Bool = false) {
        var seen = Set<String>()
        tracks = (append ? tracks + values : values).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        let wasPlaying = playing
        let resumePosition = position
        if !tracks.contains(where: { $0.id == track.id }) {
            pause()
            lyricTask?.cancel()
            track = tracks.first ?? .null
            currentArtwork = artwork(for: track)
            lyrics = track["lyrics"].array
            lyricsLoading = false
            lyricSource = nil
            position = 0
            duration = track["duration"].number
            queueTracks = [:]
            native.queue = ApplicationMusicPlayer.Queue(for: [Song]())
            loadedTrackID = ""
            synchronize()
        } else if track != .null {
            select(track, autoplay: wasPlaying, resumePosition: resumePosition)
        }
    }
    func remove(_ id: String) { setQueue(tracks.filter { $0.id != id }) }
    func cycleMode() {
        let modes = ["order", "repeat", "single", "random"]
        mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count]
        applyPlaybackMode()
    }
    private func applyPlaybackMode() {
        native.state.repeatMode = mode == "single" ? .one : mode == "repeat" ? .all : MusicKit.MusicPlayer.RepeatMode.none
        native.state.shuffleMode = mode == "random" ? .songs : .off
    }
    private func loadLyrics(for value: JSONValue) {
        lyricTask?.cancel()
        lyrics = value["lyrics"].array
        lyricsLoading = false
        lyricSource = nil
        guard lyrics.isEmpty, let id = value["appleMusicId"].string.nonEmpty else { return }
        if let cached = lyricCache[id] {
            lyrics = cached
            lyricSource = cached.isEmpty ? nil : "NetEase Cloud Music"
        } else {
            lyricsLoading = true
            lyricTask = Task {
                let found = await NetEaseTimedLyrics.fetch(
                    title: value["title"].string,
                    artist: value["artist"].string,
                    duration: value["duration"].number
                )
                guard !Task.isCancelled, track.id == value.id else { return }
                lyrics = found
                lyricsLoading = false
                lyricSource = found.isEmpty ? nil : "NetEase Cloud Music"
                lyricCache[id] = found
            }
        }
    }

    func select(_ value: JSONValue) { select(value, autoplay: true, resumePosition: 0) }
    private func select(_ value: JSONValue, autoplay: Bool, resumePosition: Double) {
        playTask?.cancel()
        selection = UUID()
        let requested = selection
        native.pause()
        loadedTrackID = ""
        resolving = true
        track = value
        currentArtwork = artwork(for: value)
        loadLyrics(for: value)
        if !tracks.contains(where: { $0.id == value.id }) { tracks.append(value) }
        playing = false
        position = 0
        duration = value["duration"].number
        error = nil
        resolving = true
        synchronize()
        guard value["source"].string == "appleMusic",
              let id = value["appleMusicId"].string.nonEmpty else {
            resolving = false
            queueTracks = [:]
            native.queue = ApplicationMusicPlayer.Queue(for: [Song]())
            error = MusicError.unavailable.localizedDescription
            return
        }
        playTask = Task {
            do {
                let authorized = await MusicAuthorization.request()
                guard authorized == .authorized else { throw MusicError.permission }
                let subscription = try await MusicSubscription.current
                guard subscription.canPlayCatalogContent else { throw MusicError.subscription }
                let selected = try await song(for: id)
                var queueSongs: [Song] = []
                let queueValues = Self.playableTracks(tracks)
                for value in queueValues {
                    try Task.checkCancellation()
                    queueSongs.append(try await song(for: value["appleMusicId"].string))
                }
                try Task.checkCancellation()
                guard selection == requested else { return }
                updateArtwork(for: selected)
                native.queue = ApplicationMusicPlayer.Queue(for: queueSongs, startingAt: selected)
                queueTracks = Dictionary(uniqueKeysWithValues: zip(native.queue.entries, queueValues).map { entry, value in
                    (String(describing: entry.id), value)
                })
                loadedTrackID = value.id
                applyPlaybackMode()
                if resumePosition > 0 { native.playbackTime = resumePosition }
                if autoplay { try await native.play() }
                guard selection == requested else { return }
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
    private func updateArtwork(for song: Song) {
        currentArtwork = song.artwork
        guard currentArtwork == nil else { return }
        let requested = selection
        Task {
            let detail = try? await song.with([.albums])
            guard selection == requested, track["appleMusicId"].string == song.id.rawValue else { return }
            currentArtwork = detail?.albums?.first?.artwork
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
        if loadedTrackID != track.id || native.queue.entries.isEmpty { select(track); return }
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
        guard !tracks.isEmpty, !resolving else { return }
        if let entry = native.queue.currentEntry, queueTracks[String(describing: entry.id)] != nil {
            Task {
                do {
                    if delta > 0 { try await native.skipToNextEntry() } else { try await native.skipToPreviousEntry() }
                    synchronize()
                } catch { self.error = error.localizedDescription }
            }
            return
        }
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
    static func playableTracks(_ tracks: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        return tracks.filter { value in
            let id = value["appleMusicId"].string
            return value["source"].string == "appleMusic" && !id.isEmpty && seen.insert(id).inserted
        }
    }
    static func playableIDs(_ tracks: [JSONValue]) -> [String] { playableTracks(tracks).map { $0["appleMusicId"].string } }
    func synchronize() {
        playing = native.state.playbackStatus == .playing
        if !resolving, !loadedTrackID.isEmpty, let item = native.queue.currentEntry?.item,
           case .song(let currentSong) = item,
           let entry = native.queue.currentEntry,
           let value = queueTracks[String(describing: entry.id)], track.id != value.id {
            // Queue entry identity survives MusicKit's library/catalog ID aliases.
            // Ignore an old entry while a newly selected queue is taking effect.
            songs[currentSong.id.rawValue] = currentSong
            track = value
            loadedTrackID = value.id
            currentArtwork = native.queue.currentEntry?.artwork ?? artwork(for: value)
            duration = currentSong.duration ?? value["duration"].number
            loadLyrics(for: value)
            if currentArtwork == nil { Task { await ensureArtwork(for: value) } }
        }
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
                    let shared = command["track"]
                    guard let song = (tracks + library + [shared]).first(where: {
                        ($0.id == id || $0["appleMusicId"].string == id) && $0["source"].string == "appleMusic" && !$0["appleMusicId"].string.isEmpty
                    }) else { return }
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

// Only fetch timed lyric text. Apple Music remains the sole playback source;
// NetEase login, audio URLs, playlists and server-side lyric storage are unused.
enum NetEaseTimedLyrics {
    static func fetch(title: String, artist: String, duration: Double) async -> [JSONValue] {
        guard !title.isEmpty, !artist.isEmpty, duration > 0 else { return [] }
        do {
            let searchURL = URL(string: "https://music.163.com/api/search/get")!
            var search = URLRequest(url: searchURL)
            search.httpMethod = "POST"
            search.timeoutInterval = 8
            search.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            search.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            search.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "s", value: "\(title) \(artist)"),
                               URLQueryItem(name: "type", value: "1"),
                               URLQueryItem(name: "limit", value: "10")]
            search.httpBody = form.percentEncodedQuery?.data(using: .utf8)
            let searchData = try await data(for: search)
            let searchObject = try JSONSerialization.jsonObject(with: searchData) as? [String: Any]
            let candidates = (searchObject?["result"] as? [String: Any])?["songs"] as? [[String: Any]] ?? []
            let matching = candidates.compactMap { song -> (id: Int, distance: Double)? in
                guard normalized(song["name"] as? String ?? "") == normalized(title),
                      let names = song["artists"] as? [[String: Any]],
                      normalized(names.compactMap { $0["name"] as? String }.joined()) == normalized(artist),
                      let id = (song["id"] as? NSNumber)?.intValue else { return nil }
                let ms = (song["duration"] as? NSNumber ?? song["dt"] as? NSNumber)?.doubleValue ?? 0
                guard ms > 0 else { return nil }
                let distance = abs(ms / 1000 - duration)
                guard distance <= 8 else { return nil }
                return (id, distance)
            }
            guard let song = matching.min(by: { $0.distance < $1.distance }) else { return [] }
            var components = URLComponents(string: "https://music.163.com/api/song/lyric")!
            components.queryItems = [URLQueryItem(name: "id", value: String(song.id)),
                                     URLQueryItem(name: "lv", value: "1"),
                                     URLQueryItem(name: "tv", value: "-1")]
            var lyricRequest = URLRequest(url: components.url!)
            lyricRequest.timeoutInterval = 8
            lyricRequest.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            lyricRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let lyricData = try await data(for: lyricRequest)
            let lyricObject = try JSONSerialization.jsonObject(with: lyricData) as? [String: Any]
            let lrc = (lyricObject?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
            return parse(lrc)
        } catch { return [] }
    }

    private static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, data.count <= 256_000 else { return Data() }
        return data
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func parse(_ lrc: String) -> [JSONValue] {
        guard lrc.utf8.count <= 256_000,
              let timestamps = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#) else { return [] }
        var parsed: [(Double, String)] = []
        for raw in lrc.split(separator: "\n").prefix(1000) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = timestamps.matches(in: line, range: range)
            guard let last = matches.last,
                  let end = Range(NSRange(location: last.range.location + last.range.length, length: 0), in: line) else { continue }
            let lyric = String(line[end.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyric.isEmpty else { continue }
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: line),
                      let secondsRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minutesRange]),
                      let seconds = Double(line[secondsRange]) else { continue }
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: line) {
                    let digits = line[fractionRange]
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                parsed.append((minutes * 60 + seconds + fraction, lyric))
            }
        }
        return parsed.sorted { $0.0 < $1.0 }.map { time, text in
            .object(["time": .number(time), "text": .string(text)])
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
    @Published private(set) var playlistCovers: [String: MusicKit.Artwork] = [:]
    private var playlistCoverLookups = Set<String>()

    func artwork(for playlist: JSONValue) -> MusicKit.Artwork? {
        playlistItems[playlist.id]?.artwork ?? playlistCovers[playlist.id]
    }

    func ensurePlaylistArtwork(for id: String, player: MusicPlayer) async {
        guard let playlist = playlistItems[id], playlist.artwork == nil, playlistCovers[id] == nil,
              playlistCoverLookups.insert(id).inserted else { return }
        do {
            let detailed = try await playlist.with([.tracks])
            playlistItems[id] = detailed
            let songs = detailed.tracks?.compactMap { item -> Song? in
                if case .song(let song) = item { return song }
                return nil
            } ?? []
            if let image = songs.lazy.compactMap(\.artwork).first {
                playlistCovers[id] = image
            } else if let song = songs.first {
                player.register([song])
                let value = Self.metadata(song)
                await player.ensureArtwork(for: value)
                if let image = player.artwork(for: value) { playlistCovers[id] = image }
            }
        } catch { playlistCoverLookups.remove(id) }
    }

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
            playlistCovers = [:]
            playlistCoverLookups = []
            playlists = items.map { .object(["id": .string($0.id.rawValue),
                                            "name": .string($0.name),
                                            "cover": .string($0.artwork?.url(width: 200, height: 200)?.absoluteString ?? "")]) }
        } catch { message = error.localizedDescription }
    }
    func mySongs(player: MusicPlayer) async {
        guard !busy, connected else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            var request = MusicLibraryRequest<Song>()
            request.limit = 100
            var page = try await request.response().items
            var allSongs = Array(page)
            while page.hasNextBatch, let next = try await page.nextBatch(limit: 100), !next.isEmpty {
                allSongs.append(contentsOf: next)
                page = next
            }
            player.register(allSongs)
            songs = allSongs.map(Self.metadata)
            collection = .object(["title": .string("My songs"), "tracks": .array(songs)])
        } catch { message = error.localizedDescription }
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
        // Start locally before library sync: a slow save must not later reset
        // a queue the user has already advanced with Next.
        if autoplay, let first = values.first { player.select(first) }
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
        message = saved ? "" : "Queue updated on this phone; library sync failed."
    }
}
