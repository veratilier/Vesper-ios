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
    private let player = AVPlayer()
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let d = self.player.currentItem?.duration.seconds ?? 0; self.duration = d.isFinite ? d : 0
                self.playing = self.player.rate > 0
                self.publishNowPlaying()
            }
        }
        MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        MPRemoteCommandCenter.shared().nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next(1) }; return .success }
        MPRemoteCommandCenter.shared().previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next(-1) }; return .success }
    }
    func updateLibrary(_ values: [JSONValue]) { tracks = values; if track == .null { track = values.first ?? .null } }
    func select(_ value: JSONValue) {
        guard let url = URL(string: value["url"].string), url.scheme == "https" else { error = "This song has no playable HTTPS audio URL. Refresh its source in Vesper."; return }
        track = value; position = 0; duration = 0
        let item = AVPlayerItem(url: url)
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed { Task { @MainActor in self?.error = "This audio could not be played. Its link may have expired."; self?.playing = false } }
        }
        player.replaceCurrentItem(with: item); play()
    }
    func play() {
        if player.currentItem == nil { if track != .null { select(track) }; return }
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default); try AVAudioSession.sharedInstance().setActive(true); player.play() }
        catch { self.error = error.localizedDescription }
    }
    func pause() { player.pause(); playing = false }
    func toggle() { playing ? pause() : play() }
    func next(_ delta: Int) { guard !tracks.isEmpty else { return }; let index = tracks.firstIndex { $0.id == track.id } ?? 0; select(tracks[(index + delta + tracks.count) % tracks.count]) }
    func seek(_ value: Double) { player.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
    private func publishNowPlaying() {
        guard track != .null else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track["title"].string, MPMediaItemPropertyArtist: track["artist"].string, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    }
}
