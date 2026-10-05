import SwiftUI
import MusicKit

enum ChatMusicShare {
    static func links(in text: String) -> [JSONValue] {
        var seen = Set<String>()
        return ChatMarkdownText.render(text).runs.compactMap { $0.link }.compactMap { url in
            guard ChatWebURL.accepts(url), let host = url.host?.lowercased(), seen.insert(url.absoluteString).inserted else { return nil }
            guard host == "music.apple.com" else { return nil }
            let provider = "Apple Music"
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let song = host == "music.apple.com" ? (query?.first { $0.name == "i" }?.value ?? (url.path.contains("/song/") ? url.lastPathComponent : "")) : ""
            return .object(["id": .string("share:" + url.absoluteString), "title": .string(provider), "artist": .string("Shared music"),
                            "source": .string(song.isEmpty ? "link" : "appleMusic"), "appleMusicId": .string(song), "appleMusicURL": .string(url.absoluteString), "provider": .string(provider)])
        }.prefix(2).map { $0 }
    }
    static func isApple(_ value: JSONValue) -> Bool {
        if value["source"].string == "netease" || !value["neteaseId"].string.isEmpty
            || value.id.hasPrefix("netease-") || value["trackId"].string.hasPrefix("netease-") { return false }
        return !value["appleMusicId"].string.isEmpty
            || URL(string: value["appleMusicURL"].string)?.host?.lowercased() == "music.apple.com"
    }
    static func normalized(_ value: JSONValue) -> JSONValue {
        var track = value
        if track.id.isEmpty { track["id"] = track["trackId"] }
        if !track["appleMusicId"].string.isEmpty { track["source"] = .string("appleMusic") }
        return track
    }
    static func coverURL(_ value: JSONValue) -> String {
        for key in ["cover", "artwork"] {
            guard var components = URLComponents(string: value[key].string),
                  let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  components.host != nil, components.user == nil, components.password == nil else { continue }
            components.scheme = "https"
            return components.url?.absoluteString ?? ""
        }
        return ""
    }
    static func mergingMetadata(_ original: JSONValue, lookup: JSONValue) -> JSONValue {
        var value = normalized(original)
        for key in ["title", "artist", "album", "appleMusicURL"] {
            if lookup[key] != .null && !lookup[key].string.isEmpty { value[key] = lookup[key] }
        }
        if lookup["duration"].number > 0 { value["duration"] = lookup["duration"] }
        if !coverURL(lookup).isEmpty { value["cover"] = .string(coverURL(lookup)) }
        return value
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
    var body: some View {
        Group {
            if ChatMusicShare.isApple(track) { ChatMusicCardContent(track: track) }
            else {
                // Keep old shared songs readable without rendering a non-Apple card.
                let title = [track["title"].string, track["artist"].string].filter { !$0.isEmpty }.joined(separator: " · ")
                if let url = URL(string: track["shareURL"].string), ChatWebURL.accepts(url) {
                    Link(title.isEmpty ? "Shared music link" : title, destination: url)
                } else { Text(title.isEmpty ? "Shared music" : title) }
            }
        }.modifier(ChatInAppLinks())
    }
}
private struct ChatMusicCardContent: View {
    let track: JSONValue
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL
    @AppStorage("vesperPalette") private var palette = "blue"
    @State private var resolved: JSONValue?
    @State private var albumTracks: [JSONValue] = []
    @State private var playbackError: String?
    private var colors: VesperPalette { VesperPalette(rawValue: palette) ?? .blue }
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
                cover.frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Album cover")
                VStack(alignment: .leading, spacing: 4) {
                    Text(song["title"].string).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(song["artist"].string).font(.caption).foregroundStyle(colors.muted).lineLimit(1)
                    Text(song["source"].string.hasPrefix("apple") ? " Music" : (song["provider"].string.isEmpty ? "Shared song" : song["provider"].string))
                        .font(.caption2).foregroundStyle(colors.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: playable ? (selected ? "pause.fill" : "play.fill") : "arrow.up.right").foregroundStyle(colors.ink)
            }.frame(maxWidth: 265, alignment: .leading).padding(12)
                .foregroundStyle(colors.ink)
                .vesperGlass(in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette == "black" ? Color.white.opacity(0.16) : Color.white.opacity(0.65), lineWidth: 1))
        }.buttonStyle(.plain).disabled(!playable && shareURL == nil)
            .accessibilityLabel((playable ? "Play " : "Open ") + song["title"].string)
            .task(id: track.id) { await resolve() }
            .onChange(of: player.error) { _, error in if player.track.id == song.id || albumTracks.contains(where: { $0.id == player.track.id }) { playbackError = error } }
            .alert("Apple Music", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                Button("OK") { playbackError = nil }
            } message: { Text(playbackError ?? "") }
    }
    @ViewBuilder private var cover: some View {
        if let artwork = player.artwork(for: song) ?? player.artwork(for: track) {
            MusicKit.ArtworkImage(artwork, width: 56, height: 56)
        } else {
            Artwork(url: ChatMusicShare.coverURL(song))
        }
    }
    private func resolve() async {
        if ChatMusicShare.coverURL(track).isEmpty, MusicAuthorization.currentStatus == .authorized {
            await player.ensureArtwork(for: track)
        }
        // Public metadata needs neither a developer token nor Music permission.
        // Playback authorization is requested only when the user taps Play.
        let id = MusicPlayer.storeID(track)
        let url = shareURL.flatMap { $0.host == "music.apple.com" ? $0 : nil }
        let isAlbum = id == nil && (url?.path.contains("/album/") ?? false)
        guard let lookupID = id ?? (isAlbum ? url?.lastPathComponent : nil),
              !lookupID.isEmpty, lookupID.allSatisfy(\.isNumber) else { return }
        let region = url?.pathComponents.dropFirst().first ?? "cn"
        for country in (region == "tw" ? [region] : [region, "tw"]) {
            if Task.isCancelled { return }
            var lookup = URLComponents(string: "https://itunes.apple.com/lookup")!
            lookup.queryItems = [URLQueryItem(name: "id", value: lookupID), URLQueryItem(name: "country", value: country), URLQueryItem(name: "entity", value: "song")]
            guard let endpoint = lookup.url,
                  let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: endpoint, timeoutInterval: 10)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try? JSONDecoder().decode(JSONValue.self, from: data), !Task.isCancelled else { continue }
            let tracks = body["results"].array.compactMap(ChatMusicShare.appleMetadata)
            if let id, let match = tracks.first(where: { $0["appleMusicId"].string == id }) {
                resolved = ChatMusicShare.mergingMetadata(track, lookup: match)
                return
            }
            if isAlbum, let album = body["results"].array.first(where: { $0["wrapperType"].string == "collection" }), !tracks.isEmpty {
                albumTracks = tracks
                resolved = .object(["id": track["id"], "source": .string("appleAlbum"), "title": album["collectionName"], "artist": album["artistName"], "cover": album["artworkUrl100"]])
                return
            }
        }
        // Retain supplied metadata and the original link when lookup fails.
    }
}

struct ChatMusicSharePicker: View {
    let onSelect: (JSONValue) -> Void
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = MusicCatalog()
    @State private var query = ""
    @State private var searched = false
    private var tracks: [JSONValue] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return store.document("music").array.filter { ChatMusicShare.isApple($0) } }
        return searched && !catalog.busy ? catalog.collection["tracks"].array : []
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("Search songs or artists", text: $query).submitLabel(.search).onSubmit(search)
                        Button(action: search) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                            .accessibilityLabel("Search music").disabled(catalog.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.leading, 14).vesperGlass(in: RoundedRectangle(cornerRadius: 14))
                    Text(query.isEmpty ? "Your music" : "Search results").font(.headline)
                    if catalog.busy { ProgressView("Searching…") }
                    if !catalog.message.isEmpty && !query.isEmpty { Text(catalog.message).font(.footnote).foregroundStyle(VesperTheme.muted) }
                    ForEach(tracks) { track in
                        Button { onSelect(ChatMusicShare.normalized(track)) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: track["cover"].string)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(VesperTheme.surface) }
                                    .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(track["title"].string).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                    Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up").font(.system(size: 17))
                            }.padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                    if tracks.isEmpty && !catalog.busy && query.isEmpty { Text("Search for a song to share.").foregroundStyle(VesperTheme.muted) }
                    Text("Choose a song, then send its card from the composer.").font(.caption).foregroundStyle(VesperTheme.muted)
                }.padding(20)
            }.background { Background() }.foregroundStyle(VesperTheme.ink)
                .navigationTitle("Share music").navigationBarTitleDisplayMode(.inline)
                .onChange(of: query) { _, _ in searched = false }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
    private func search() {
        guard !catalog.busy, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searched = true; let term = query
        Task { await catalog.search(term, api: store.api) }
    }
}
