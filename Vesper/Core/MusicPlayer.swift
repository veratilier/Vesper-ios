import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor final class MusicPlayer: ObservableObject {
    @Published var tracks: [JSONValue] = []
    @Published var track: JSONValue = .null
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var mode = "order"
    @Published var resolving = false
    private var initialized = false
    private var resolveTask: Task<Void, Never>?
    private var api: APIClient?
    private var endObserver: NSObjectProtocol?
    private var audioObservers: [NSObjectProtocol] = []
    private var playbackObserver: NSKeyValueObservation?
    private var selection = UUID()
    func configure(_ store: AppStore) { api = store.api }
    private let player = AVPlayer()
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    init() {
        playbackObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.synchronize() }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification] {
            audioObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    guard let self else { return }
                    if name == AVAudioSession.mediaServicesWereResetNotification {
                        self.pause(); self.player.replaceCurrentItem(with: nil)
                        self.position = 0; self.duration = 0
                        self.error = "Audio was reset. Tap play to reload this song."
                    } else if (name == AVAudioSession.interruptionNotification && raw == AVAudioSession.InterruptionType.began.rawValue) || reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                        self.pause()
                    }
                    self.synchronize()
                }
            })
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                if self.mode == "single" { self.seek(0); self.play() }
                else if self.mode == "order", self.tracks.last?.id == self.track.id { self.pause() }
                else { self.next(1) }
            }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let d = self.player.currentItem?.duration.seconds ?? 0; self.duration = d.isFinite ? d : 0
                self.playing = self.player.timeControlStatus == .playing
                self.publishNowPlaying()
            }
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next(1) }; return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next(-1) }; return .success }
    }
    func updateLibrary(_ values: [JSONValue]) {
        guard !initialized else { return }
        tracks = values
        if !values.isEmpty { initialized = true }
        if track == .null { track = values.first ?? .null }
    }
    func setQueue(_ values: [JSONValue], append: Bool = false) {
        var seen = Set<String>()
        tracks = (append ? tracks + values : values).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        initialized = true
        if !tracks.contains(where: { $0.id == track.id }) { pause(); player.replaceCurrentItem(with: nil); track = tracks.first ?? .null; position = 0; duration = 0; synchronize() }
    }
    func remove(_ id: String) { setQueue(tracks.filter { $0.id != id }) }
    func cycleMode() { let modes = ["order", "repeat", "single", "random"]; mode = modes[((modes.firstIndex(of: mode) ?? 0) + 1) % modes.count] }
    func select(_ value: JSONValue) {
        resolveTask?.cancel(); selection = UUID()
        let requested = selection
        resolving = false
        player.pause(); player.replaceCurrentItem(with: nil)
        error = nil; track = value; position = 0; duration = 0; synchronize()
        let id = value["neteaseId"].string
        guard !id.isEmpty, let api else { start(value); return }
        player.pause(); synchronize(); resolving = true
        resolveTask = Task {
            do {
                let result = try await MusicCatalog.request(api, action: "resolve", payload: ["songIds": .array([.string(id)]), "tracks": .array([value])])
                try Task.checkCancellation()
                guard selection == requested else { return }
                guard let resolved = result["tracks"].array.first else { throw ServiceError(message: "No playable source was returned for this song.") }
                if let index = tracks.firstIndex(where: { $0.id == resolved.id }) { tracks[index] = resolved }
                resolving = false; start(resolved)
            } catch { if !Task.isCancelled { resolving = false; self.error = error.localizedDescription } }
        }
    }
    func start(_ value: JSONValue) {
        resolveTask?.cancel(); selection = UUID(); resolving = false
        player.pause(); player.replaceCurrentItem(with: nil)
        error = nil; track = value; position = 0; duration = 0; synchronize()
        guard let url = URL(string: value["url"].string), url.scheme == "https" else { error = "This song has no playable HTTPS audio URL. Refresh its source in Vesper."; return }
        track = value; position = 0; duration = 0
        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in
                guard let self, item === self.player.currentItem else { return }
                self.error = "This audio could not be played. Its link may have expired."; self.player.pause(); self.synchronize()
            } }
        }
        player.replaceCurrentItem(with: item); synchronize(); play()
    }
    func play() {
        guard !resolving else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed { if track != .null { select(track) }; return }
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try AVAudioSession.sharedInstance().setActive(true); player.play(); synchronize() }
        catch { self.error = error.localizedDescription }
    }
    func pause() { selection = UUID(); resolveTask?.cancel(); resolving = false; player.pause(); synchronize() }
    func toggle() { playing ? pause() : play() }
    func next(_ delta: Int) { guard !tracks.isEmpty else { return }; if mode == "random", tracks.count > 1, let choice = tracks.filter({ $0.id != track.id }).randomElement() { select(choice); return }; let index = tracks.firstIndex { $0.id == track.id } ?? 0; select(tracks[(index + delta + tracks.count) % tracks.count]) }
    func seek(_ value: Double) { player.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
    func synchronize() {
        playing = player.timeControlStatus == .playing && player.currentItem?.status != .failed
        let time = player.currentTime().seconds
        position = time.isFinite ? max(0, time) : 0
        let total = player.currentItem?.duration.seconds ?? 0
        duration = total.isFinite ? max(0, total) : 0
        publishNowPlaying()
    }
    private func publishNowPlaying() {
        guard track != .null else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track["title"].string, MPMediaItemPropertyArtist: track["artist"].string, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    }
}


@MainActor final class MusicCatalog: ObservableObject {
    @Published var uid = UserDefaults.standard.string(forKey: "netease-uid") ?? ""
    @Published var cookie = CredentialStore.read(account: "netease-music-u")
    @Published var playlists: [JSONValue] = []
    @Published var collection: JSONValue = .null
    @Published var busy = false
    @Published var message = ""
    @Published var connected = false
    static func request(_ api: APIClient, action: String, payload: [String: JSONValue] = [:], uid: String? = nil, cookie: String? = nil) async throws -> JSONValue {
        var body = payload
        body["action"] = .string(action)
        body["uid"] = .string(uid ?? UserDefaults.standard.string(forKey: "netease-uid") ?? "")
        body["cookie"] = .string(cookie ?? CredentialStore.read(account: "netease-music-u"))
        let result = try await api.request("/api/music/library", method: "POST", body: .object(body))
        if !result["error"].string.isEmpty { throw ServiceError(message: result["error"].string) }
        return result
    }
    func connect(_ store: AppStore) async {
        guard !busy else { return }
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Enter your NetEase UID and MUSIC_U."; return }
        busy = true; message = ""; defer { busy = false }
        do {
            let result = try await Self.request(store.api, action: "playlists", uid: uid.trimmingCharacters(in: .whitespacesAndNewlines), cookie: cookie.trimmingCharacters(in: .whitespacesAndNewlines))
            guard case .array = result["playlists"] else { throw ServiceError(message: "The service returned no playlist data.") }
            try CredentialStore.save(cookie.trimmingCharacters(in: .whitespacesAndNewlines), account: "netease-music-u")
            UserDefaults.standard.set(uid.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "netease-uid")
            playlists = result["playlists"].array; connected = true; message = "Account connected · playlists refreshed"
        } catch { connected = false; message = error.localizedDescription }
    }
    func load(_ action: String, store: AppStore, payload: [String: JSONValue] = [:]) async {
        guard !busy else { return }; busy = true; message = ""; defer { busy = false }
        do { collection = try await Self.request(store.api, action: action, payload: payload) }
        catch { message = error.localizedDescription }
    }
    func prepare(_ values: [JSONValue], store: AppStore, player: MusicPlayer, append: Bool = false, autoplay: Bool = true) async {
        guard !busy, !values.isEmpty else { return }; busy = true; message = ""; defer { busy = false }
        do {
            let ids = values.map { $0["neteaseId"].string.isEmpty ? $0.id.replacingOccurrences(of: "netease-", with: "") : $0["neteaseId"].string }
            let result = try await Self.request(store.api, action: "resolve", payload: ["songIds": .array(ids.map(JSONValue.string)), "tracks": .array(values)])
            let resolved = result["tracks"].array
            guard !resolved.isEmpty else { throw ServiceError(message: "No songs were returned. Try another collection.") }
            player.setQueue(resolved, append: append)
            let saved = await store.mutate("music") { current in
                var merged = current.array
                for value in resolved { if let index = merged.firstIndex(where: { $0.id == value.id }) { merged[index] = value } else { merged.append(value) } }
                return .array(merged)
            }
            message = saved ? "Added \(resolved.count) songs to the queue" : "Queue updated on this phone; library sync failed."
            if autoplay, let first = resolved.first { player.start(first) }
        } catch { message = error.localizedDescription }
    }
}
