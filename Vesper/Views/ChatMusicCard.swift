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
        return track
    }
}

struct ChatMusicLinkCard: View {
    let track: JSONValue
    @State private var resolved: JSONValue?
    var body: some View {
        ChatMusicCard(track: resolved ?? track)
            .task(id: track["appleMusicId"].string) {
                let id = track["appleMusicId"].string
                guard !id.isEmpty else { return }
                do {
                    let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(id))
                    if let song = try await request.response().items.first { resolved = MusicCatalog.metadata(song) }
                } catch { /* Keep the real shared URL usable when metadata is unavailable. */ }
            }
    }
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
    private var selected: Bool { player.track.id == track.id && player.playing }
    private var playable: Bool { track["source"].string == "appleMusic" && !track["appleMusicId"].string.isEmpty }
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
                if selected { player.pause() } else { player.select(track) }
            } else if let url = shareURL { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                Artwork(url: track["cover"].string.isEmpty ? track["artwork"].string : track["cover"].string).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(track["title"].string).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                    Text(track["source"].string == "appleMusic" ? "Apple Music" : (track["provider"].string.isEmpty ? "Shared song" : track["provider"].string))
                        .font(.caption2).foregroundStyle(VesperTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: playable ? (selected ? "pause.fill" : "play.fill") : "arrow.up.right")
            }.frame(maxWidth: 240, alignment: .leading).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(!playable && shareURL == nil)
            .accessibilityLabel((playable ? "Play " : "Open ") + track["title"].string)

    }
}
