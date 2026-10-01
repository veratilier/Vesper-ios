import SwiftUI
import MusicKit

enum ChatMusicShare {
    static func links(in text: String) -> [JSONValue] {
        var seen = Set<String>()
        return ChatMarkdownText.render(text).runs.compactMap { $0.link }.compactMap { url in
            guard ChatWebURL.accepts(url), let host = url.host?.lowercased(), seen.insert(url.absoluteString).inserted else { return nil }
            let provider: String
            switch host {
            case "music.apple.com": provider = "Apple Music"
            case "open.spotify.com": provider = "Spotify"
            case "music.163.com", "y.music.163.com": provider = "网易云音乐"
            default: return nil
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let song = host == "music.apple.com" ? (query?.first { $0.name == "i" }?.value ?? (url.path.contains("/song/") ? url.lastPathComponent : "")) : ""
            return .object(["id": .string("share:" + url.absoluteString), "title": .string(provider), "artist": .string("Shared music"),
                            "source": .string(song.isEmpty ? "link" : "appleMusic"), "appleMusicId": .string(song), "appleMusicURL": .string(url.absoluteString), "provider": .string(provider)])
        }.prefix(2).map { $0 }
    }
    static func normalized(_ value: JSONValue) -> JSONValue {
        var track = value
        if track.id.isEmpty { track["id"] = track["trackId"] }
        if !track["appleMusicId"].string.isEmpty { track["source"] = .string("appleMusic") }
        return track
    }
    static func appleMetadata(_ value: JSONValue) -> JSONValue? {
        guard value["kind"].string == "song", value["trackId"].number > 0,
              !value["trackName"].string.isEmpty, !value["artistName"].string.isEmpty else { return nil }
        let id = String(Int(value["trackId"].number))
        return .object(["id": .string("apple-" + id), "source": .string("appleMusic"), "appleMusicId": .string(id),
            "appleMusicURL": value["trackViewUrl"], "title": value["trackName"], "artist": value["artistName"],
            "album": value["collectionName"], "cover": value["artworkUrl100"], "duration": .number(value["trackTimeMillis"].number / 1000)])
    }
}

struct ChatMusicLinkCard: View {
    let track: JSONValue
    var body: some View { ChatMusicCard(track: track) }
}

struct ChatMusicCard: View {
    let track: JSONValue
    var body: some View { ChatMusicCardContent(track: track).modifier(ChatInAppLinks()) }
}
private struct ChatMusicCardContent: View {
    let track: JSONValue
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    @State private var resolved: JSONValue?
    @State private var albumTracks: [JSONValue] = []
    @State private var playbackError: String?
    private var song: JSONValue { resolved ?? ChatMusicShare.normalized(track) }
    private var selected: Bool { (player.track.id == song.id || albumTracks.contains { $0.id == player.track.id }) && player.playing }
    private var playable: Bool { !song["appleMusicId"].string.isEmpty || !albumTracks.isEmpty }
    private var shareURL: URL? {
        for key in ["appleMusicURL", "shareURL"] {
            if let url = URL(string: track[key].string), ChatWebURL.accepts(url) { return url }
        }
        return nil
    }
    var body: some View {
        Button {
            if playable {
                player.configure(store)
                if selected { player.pause() }
                else if let first = albumTracks.first { player.setQueue(albumTracks); player.select(first) }
                else { player.select(song) }
            } else if let url = shareURL { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                Artwork(url: song["cover"].string.isEmpty ? song["artwork"].string : song["cover"].string).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(song["title"].string).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(song["artist"].string).font(.caption).foregroundStyle(Color(red: 0.55, green: 0.24, blue: 0.30)).lineLimit(1)
                    Text(song["source"].string.hasPrefix("apple") ? " Music" : (song["provider"].string.isEmpty ? "Shared song" : song["provider"].string))
                        .font(.caption2).foregroundStyle(Color(red: 0.55, green: 0.24, blue: 0.30))
                }
                Spacer(minLength: 4)
                Image(systemName: playable ? (selected ? "pause.fill" : "play.fill") : "arrow.up.right").foregroundStyle(Color(red: 0.98, green: 0.20, blue: 0.34))
            }.frame(maxWidth: 265, alignment: .leading).padding(12)
                .foregroundStyle(Color(red: 0.16, green: 0.12, blue: 0.14))
                .background(Color(red: 1, green: 0.96, blue: 0.97).opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(!playable && shareURL == nil)
            .accessibilityLabel((playable ? "Play " : "Open ") + song["title"].string)
            .task(id: track.id) { await resolve() }
            .onChange(of: player.error) { _, error in if player.track.id == song.id || albumTracks.contains(where: { $0.id == player.track.id }) { playbackError = error } }
            .alert("Apple Music", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                Button("OK") { playbackError = nil }
            } message: { Text(playbackError ?? "") }
    }
    private func resolve() async {
        var id = track["appleMusicId"].string
        if id.isEmpty, let url = shareURL, url.host == "music.apple.com" {
            id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "i" }?.value ?? (url.path.contains("/song/") ? url.lastPathComponent : "")
        }
        // Public catalog metadata also fills cards before Music authorization.
        if let url = shareURL, url.host == "music.apple.com" {
            let lookupID = id.isEmpty ? url.lastPathComponent : id
            let region = url.pathComponents.dropFirst().first ?? "cn"
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [URLQueryItem(name: "id", value: lookupID), URLQueryItem(name: "country", value: region), URLQueryItem(name: "entity", value: "song")]
            if let endpoint = lookup.url,
               let (data, response) = try? await URLSession.shared.data(from: endpoint),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let body = try? JSONDecoder().decode(JSONValue.self, from: data), !Task.isCancelled {
                let tracks = body["results"].array.compactMap(ChatMusicShare.appleMetadata)
                if !id.isEmpty, let match = tracks.first(where: { $0["appleMusicId"].string == id }) { resolved = match }
                else if id.isEmpty, let album = body["results"].array.first, !tracks.isEmpty {
                    albumTracks = tracks
                    resolved = .object(["id": track["id"], "source": .string("appleAlbum"), "title": album["collectionName"], "artist": album["artistName"], "cover": album["artworkUrl100"]])
                }
            }
        }
        guard !Task.isCancelled, MusicAuthorization.currentStatus == .authorized else { return }
        do {
            if !id.isEmpty {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                if let value = try await request.response().items.first {
                    player.register([value]); resolved = MusicCatalog.metadata(value)
                    await player.ensureArtwork(for: resolved ?? track)
                }
            } else if let url = shareURL, url.host == "music.apple.com", url.path.contains("/album/") {
                let request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(url.lastPathComponent))
                if let album = try await request.response().items.first {
                    let detail = try await album.with([.tracks])
                    let songs: [Song] = detail.tracks?.compactMap { item -> Song? in if case .song(let song) = item { return song }; return nil } ?? []
                    player.register(songs); albumTracks = songs.map(MusicCatalog.metadata)
                    resolved = .object(["id": track["id"], "source": .string("appleAlbum"), "title": .string(album.title),
                        "artist": .string(album.artistName), "cover": .string(album.artwork?.url(width: 300, height: 300)?.absoluteString ?? "")])
                }
            }
        } catch { /* The original URL remains accessible if catalog access is unavailable. */ }
    }
}
