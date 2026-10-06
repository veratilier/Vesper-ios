import SwiftUI
import MusicKit
struct Artwork: View {
    let url: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack { VesperTheme.accent.opacity(0.2); Image(systemName: "music.note").font(.largeTitle).foregroundStyle(VesperTheme.muted) }
        }.clipped()
    }
}
private struct NowPlayingArtwork: View {
    let artwork: MusicKit.Artwork?
    let url: String
    let size: CGFloat
    var body: some View {
        Group {
            if let artwork {
                MusicKit.ArtworkImage(artwork, width: size, height: size)
            } else {
                Artwork(url: url)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel("Album cover")
    }
}
struct PlaybackControls: View {
    @EnvironmentObject private var player: MusicPlayer
    var body: some View {
        HStack {
            Button { player.next(-1) } label: { Image(systemName: "backward.end") }.accessibilityLabel("Previous song")
            Spacer()
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(player.playing ? "Pause" : "Play")
            Spacer()
            Button { player.next(1) } label: { Image(systemName: "forward.end") }.accessibilityLabel("Next song")
        }.padding(.horizontal, 10).disabled(player.tracks.isEmpty)
    }
}
struct MusicView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var catalog = MusicCatalog()
    @State private var sheet: MusicSheet?
    @State private var showingLyrics: Bool
    @AppStorage("music.lyricsFrostedBackground") private var lyricsFrostedBackground = true
    private enum MusicSheet: String, Identifiable { case library, queue; var id: String { rawValue } }
    init(showingLyrics: Bool = false) { _showingLyrics = State(initialValue: showingLyrics) }
    #if DEBUG
    private var dockObserver: ((CGRect) -> Void)?
    init(showingLyrics: Bool, observeDock: @escaping (CGRect) -> Void) {
        _showingLyrics = State(initialValue: showingLyrics); dockObserver = observeDock
    }
    #endif
    var body: some View {
        GeometryReader { geometry in
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button { player.cycleMode() } label: {
                            Image(systemName: playbackModeIcon)
                                .font(.system(size: 19))
                                .frame(width: 42, height: 42)
                                .vesperMaterial(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Playback mode: \(playbackModeName). Tap to change")
                        Button { sheet = .library } label: {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 19))
                                .frame(width: 42, height: 42)
                                .vesperMaterial(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("My Music")
                    }
                    TabView(selection: $showingLyrics) {
                        GeometryReader { area in
                            let size = max(100, min(area.size.width, area.size.height - 110, 460))
                            ScrollView {
                                VStack(spacing: 16) {
                                    NowPlayingArtwork(artwork: player.currentArtwork,
                                                      url: player.track["cover"].string, size: size)
                                        .frame(maxWidth: .infinity)
                                    trackCopy
                                }.padding(.vertical, 8)
                            }
                        }.tag(false)
                        lyricsPanel.tag(true)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    .accessibilityHint("Swipe sideways to switch between the album cover and lyrics")
                    VStack(spacing: 12) { progress; controls }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("music-playback-dock")
                        #if DEBUG
                        .background {
                            if let dockObserver {
                                GeometryReader { area in
                                    let frame = area.frame(in: .global)
                                    Color.clear.onAppear { dockObserver(frame) }.onChange(of: frame) { _, value in dockObserver(value) }
                                }
                            }
                        }
                        #endif
                }.padding(.horizontal, 26).padding(.top, 4).padding(.bottom, 20)
                    .frame(maxWidth: 580).frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .task { player.configure(store); player.updateLibrary(store.document("music").array) }
        .onChange(of: store.document("music")) { _, value in player.updateLibrary(value.array) }
        .sheet(item: $sheet) { item in
            if item == .library { MusicLibraryView(catalog: catalog) }
            else { queueSheet.presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        }
        .alert("Music", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("OK") { player.error = nil } } message: { Text(player.error ?? "") }
    }
    private var playbackModeIcon: String {
        switch player.mode {
        case "repeat": "repeat"
        case "single": "repeat.1"
        case "random": "shuffle"
        default: "text.line.first.and.arrowtriangle.forward"
        }
    }
    private var playbackModeName: String {
        switch player.mode {
        case "repeat": "Repeat all"
        case "single": "Repeat one"
        case "random": "Shuffle"
        default: "In order"
        }
    }
    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                NowPlayingArtwork(artwork: player.currentArtwork,
                                  url: player.track["cover"].string, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.track["title"].string).font(.headline).lineLimit(1)
                    Text(player.track["artist"].string).font(.subheadline)
                        .foregroundStyle(VesperTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { lyricsFrostedBackground.toggle() } label: {
                    Image(systemName: lyricsFrostedBackground ? "square.on.square.fill" : "square.dashed")
                        .font(.system(size: 19))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(lyricsFrostedBackground ? "Turn off frosted lyrics background" : "Turn on frosted lyrics background")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    let lines = player.lyrics
                    if player.lyricsLoading {
                        ProgressView("Finding timed lyrics…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if lines.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "text.quote").font(.largeTitle)
                            Text("No matching timed lyrics found for this version.")
                                .multilineTextAlignment(.center)
                            if let url = URL(string: player.track["appleMusicURL"].string),
                               url.scheme == "https" {
                                Link("View lyrics in Apple Music", destination: url)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .foregroundStyle(VesperTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 220)
                        .padding()
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line["text"].string)
                                    .font(.system(size: 18, weight: line["time"].number <= player.position ? .semibold : .regular))
                                    .foregroundStyle(line["time"].number <= player.position ? VesperTheme.ink : VesperTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 16)
                        if let source = player.lyricSource {
                            Text("Lyrics: \(source)")
                                .font(.caption).foregroundStyle(VesperTheme.muted).padding(.horizontal, 18)
                        }
                    }
                }
                .onChange(of: Int(player.position)) { _, _ in
                    let lines = player.lyrics
                    if let index = lines.indices.last(where: { lines[$0]["time"].number <= player.position }) {
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }.padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if lyricsFrostedBackground {
                    Color.clear.vesperMaterial(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(lyricsFrostedBackground ? 0.5 : 0)))
    }
    private var trackCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.track["title"].string.isEmpty ? "No song selected" : player.track["title"].string).font(.system(size: 25, weight: .semibold)).lineLimit(2)
            Text([player.track["artist"].string, player.track["album"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(VesperTheme.muted).lineLimit(2)
            if player.track == .null { Text("Open My Music to connect Apple Music or search for songs.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var progress: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { min(player.position, max(1, player.duration)) }, set: { player.seek($0) }), in: 0...max(1, player.duration)).disabled(player.duration <= 0).tint(VesperTheme.accent).accessibilityLabel("Playback position")
            HStack { Text(time(player.position)); Spacer(); Text(time(player.duration)) }.font(.caption).monospacedDigit().foregroundStyle(VesperTheme.muted)
        }
    }
    private var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                transportButton("backward.fill", label: "Previous song") { player.next(-1) }
                    .disabled(player.tracks.isEmpty || player.resolving)
                Button { player.toggle() } label: {
                    Group {
                        if player.resolving { ProgressView() }
                        else {
                            Image(systemName: player.playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 42, weight: .regular))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }.frame(maxWidth: .infinity).frame(height: 68).contentShape(Rectangle())
                }.disabled(player.tracks.isEmpty || player.resolving)
                    .accessibilityLabel(player.playing ? "Pause" : "Play")
                transportButton("forward.fill", label: "Next song") { player.next(1) }
                    .disabled(player.tracks.isEmpty || player.resolving)
            }.padding(.horizontal, 12)
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showingLyrics.toggle() }
                } label: {
                    Image(systemName: showingLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(showingLyrics ? "Show album cover" : "Show lyrics")
                    .accessibilityAddTraits(showingLyrics ? .isSelected : [])
                Spacer()
                Button { sheet = .queue } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("Queue, \(player.tracks.count) songs")
                    .overlay(alignment: .topTrailing) {
                        Text("\(player.tracks.count)").font(.system(size: 9)).foregroundStyle(VesperTheme.muted)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }.padding(.horizontal, 20).foregroundStyle(VesperTheme.muted)
        }.foregroundStyle(VesperTheme.ink)
    }
    private func transportButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 30, weight: .regular))
                .frame(maxWidth: .infinity).frame(height: 68).contentShape(Rectangle())
        }.accessibilityLabel(label)
    }
    private var queueSheet: some View {
        NavigationStack {
            List {
                if player.tracks.isEmpty { Text("The queue is empty.") }
                ForEach(player.tracks) { track in
                    Button { player.select(track); sheet = nil } label: { MusicTrackRow(track: track, active: player.track.id == track.id) }
                        .swipeActions { Button("Remove", role: .destructive) { player.remove(track.id) } }
                }
            }.scrollContentBackground(.hidden).background { Background() }.navigationTitle("Queue · \(player.tracks.count)").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }
    }
    private func time(_ seconds: Double) -> String { guard player.duration > 0 else { return "--:--" }; let s = Int(max(0, seconds)); return String(format: "%d:%02d", s / 60, s % 60) }
}

private struct MusicTrackRow: View {
    @EnvironmentObject private var player: MusicPlayer
    let track: JSONValue
    var active = false
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = player.artwork(for: track) {
                    MusicKit.ArtworkImage(artwork, width: 44, height: 44)
                } else {
                    Artwork(url: track["cover"].string)
                }
            }.frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) { Text(track["title"].string).font(.system(size: 15, weight: .medium)).lineLimit(2); Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1) }
            Spacer(minLength: 4)
            if active { Image(systemName: "waveform").foregroundStyle(VesperTheme.accent) }
        }.foregroundStyle(VesperTheme.ink).padding(.vertical, 3).contentShape(Rectangle())
            .task(id: track["appleMusicId"].string) { await player.ensureArtwork(for: track) }
    }
}

struct MusicLibraryView: View {
    @ObservedObject var catalog: MusicCatalog
    #if DEBUG
    var preview = false
    #endif
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "mine"
    @State private var query = ""
    @State private var selectedVesperPlaylistID: String?
    @State private var creatingPlaylist = false
    @State private var playlistName = ""
    @State private var playlistBusy = false
    var body: some View {
        NavigationStack {
            List {
                if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(VesperTheme.muted) }
                if let playlist = selectedVesperPlaylist { vesperCollection(playlist) }
                else if catalog.collection != .null { collection }
                else {
                    Picker("Music", selection: $tab) { Text("My Music").tag("mine"); Text("Discover").tag("discover") }.pickerStyle(.segmented)
                    if tab == "mine" {
                        vesperPlaylists
                        playlists
                    }
                    else { search }
                }
            }.scrollContentBackground(.hidden).background { Background() }
                .navigationTitle("My Music").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { if catalog.connected { await catalog.refresh(player: player) }
                                   else { await catalog.connect(player: player) } }
                        } label: {
                            if catalog.busy && tab == "mine" { ProgressView().accessibilityLabel("Loading music") }
                            else {
                                Image(systemName: catalog.connected ? "checkmark.circle.fill" : "music.note")
                                    .foregroundStyle(catalog.connected ? Color.green : VesperTheme.ink)
                            }
                        }
                        .disabled(catalog.busy)
                        .accessibilityLabel(catalog.connected ? "Apple Music connected. Refresh library" : "Connect Apple Music")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .alert("New Vesper playlist", isPresented: $creatingPlaylist) {
                    TextField("Playlist name", text: $playlistName)
                    Button("Cancel", role: .cancel) { }
                    Button("Create") {
                        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await playlistTool("music_playlist_create", arguments: .object(["name": .string(name), "requestId": .string(UUID().uuidString)])) }
                    }.disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .task {
                    #if DEBUG
                    if preview { return }
                    #endif
                    await refreshPlaylists()
                    catalog.connected = MusicAuthorization.currentStatus == .authorized
                    if catalog.connected { await catalog.refresh(player: player) }
                }
        }.presentationDragIndicator(.visible)
    }
    private var savedPlaylists: [JSONValue] { store.document("musicPlaylists").array }
    private var selectedVesperPlaylist: JSONValue? { savedPlaylists.first { $0.id == selectedVesperPlaylistID } }
    private var vesperPlaylists: some View {
        Section {
            if savedPlaylists.isEmpty { Text("Ask Rowan to make a playlist, or tap + to create one.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            ForEach(savedPlaylists) { playlist in
                Button { selectedVesperPlaylistID = playlist.id } label: {
                    HStack(spacing: 12) {
                        Artwork(url: ChatMusicShare.coverURL(playlist["tracks"].array.first ?? .null))
                            .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist["name"].string).font(.subheadline)
                            Text("\(playlist["tracks"].array.count) songs").font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(VesperTheme.ink)
                }.disabled(playlistBusy)
            }
        } header: {
            HStack {
                Text("Vesper playlists"); Spacer()
                Button { playlistName = ""; creatingPlaylist = true } label: { Image(systemName: "plus").frame(width: 36, height: 32) }
                    .accessibilityLabel("Create Vesper playlist")
            }.textCase(nil).buttonStyle(.borderless).disabled(playlistBusy)
        }
    }
    private func vesperCollection(_ playlist: JSONValue) -> some View {
        Section {
            Button { selectedVesperPlaylistID = nil } label: { Label("Back", systemImage: "chevron.left") }
            HStack {
                Text(playlist["name"].string).font(.headline); Spacer()
                Button {
                    Task {
                        await playlistTool("music_playlist_play", arguments: .object(["playlistId": .string(playlist.id)]), playback: true)
                    }
                } label: { Image(systemName: "play.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel("Play playlist").disabled(playlistBusy || playlist["tracks"].array.isEmpty)
            }
            if playlist["tracks"].array.isEmpty { Text("Find songs in Discover, then use Add to playlist.").foregroundStyle(VesperTheme.muted) }
            ForEach(playlist["tracks"].array) { track in
                Button { Task { await catalog.prepare([track], store: store, player: player, append: true) } } label: {
                    MusicTrackRow(track: track, active: player.track.id == track.id)
                }.buttonStyle(.plain).disabled(playlistBusy)
            }
        }
    }
    private func refreshPlaylists() async {
        do {
            let result = try await store.api.request("/api/codex/tools", method: "POST", body: .object(["name": .string("music_playlist_list"), "arguments": .object([:])]))
            store.documents["musicPlaylists"] = result["result"]["playlists"]
        } catch { catalog.message = error.localizedDescription }
    }
    private func playlistTool(_ name: String, arguments: JSONValue, playback: Bool = false) async {
        guard !playlistBusy else { return }
        playlistBusy = true; defer { playlistBusy = false }
        do {
            let response = try await store.api.request("/api/codex/tools", method: "POST", body: .object(["name": .string(name), "arguments": arguments]))
            if playback {
                let result = await player.applyControl(response["result"]["command"])
                if !result["pending"].bool && !result["applied"].bool { throw ServiceError(message: result["error"].string) }
            }
            await refreshPlaylists()
        } catch { catalog.message = error.localizedDescription }
    }
    private func addToPlaylist(_ track: JSONValue) -> some View {
        Menu {
            if savedPlaylists.isEmpty { Text("Create a Vesper playlist first") }
            ForEach(savedPlaylists) { playlist in
                Button(playlist["name"].string) {
                    // The searched/local Apple Music metadata must be available to the shared tool.
                    Task {
                        guard await store.upsert("music", item: track) else { catalog.message = "Could not save this song for the playlist."; return }
                        await playlistTool("music_playlist_add", arguments: .object(["playlistId": .string(playlist.id), "trackId": .string(track.id)]))
                    }
                }
            }
        } label: { Image(systemName: "text.badge.plus").frame(width: 44, height: 44) }
            .accessibilityLabel("Add to Vesper playlist").disabled(playlistBusy)
    }
    private var playlists: some View {
        Section {
            if catalog.playlists.isEmpty { Text("Your Apple Music playlists will appear here.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            ForEach(catalog.playlists) { playlist in
                Button { Task { await catalog.playlist(playlist.id, player: player) } } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let artwork = catalog.artwork(for: playlist) {
                                MusicKit.ArtworkImage(artwork, width: 48, height: 48)
                            } else {
                                Artwork(url: playlist["cover"].string)
                            }
                        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) { Text(playlist["name"].string).font(.subheadline) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(VesperTheme.ink)
                }.disabled(catalog.busy)
                    .task(id: playlist.id) { await catalog.ensurePlaylistArtwork(for: playlist.id, player: player) }
            }
        } header: {
            HStack {
                Text("Apple Music library")
                Spacer()
                Button { Task { await catalog.mySongs(player: player) } } label: {
                    Image(systemName: "music.note.list").frame(width: 36, height: 32)
                }
                .accessibilityLabel("My songs")
                Button { Task { await catalog.refresh(player: player) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 32)
                }
                .accessibilityLabel("Refresh library")
            }
            .font(.system(size: 15))
            .textCase(nil)
            .buttonStyle(.borderless)
            .disabled(!catalog.connected || catalog.busy)
        }
    }
    private var search: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Search songs, artists or albums", text: $query).submitLabel(.search).onSubmit(searchSongs)
                Button(action: searchSongs) {
                    Group {
                        if catalog.busy { ProgressView().accessibilityLabel("Searching music") }
                        else { Image(systemName: "magnifyingglass") }
                    }.frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Search")
                .disabled(catalog.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func searchSongs() { guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; Task { await catalog.search(query, api: store.api) } }
    private var collection: some View {
        Section {
            Button { catalog.collection = .null } label: { Label("Back", systemImage: "chevron.left") }
            HStack(spacing: 8) {
                Text(catalog.collection["title"].string.isEmpty ? "Songs" : catalog.collection["title"].string)
                    .font(.headline)
                Spacer()
                Button { Task { await catalog.prepare(catalog.collection["tracks"].array, store: store, player: player, autoplay: false) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Sync queue")
                .disabled(catalog.busy || catalog.collection["tracks"].array.isEmpty)
                Button { Task { await catalog.prepare(catalog.collection["tracks"].array, store: store, player: player) } } label: {
                    Image(systemName: "play.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless).accessibilityLabel("Play all")
                .disabled(catalog.busy || catalog.collection["tracks"].array.isEmpty)
            }
            if catalog.collection["tracks"].array.isEmpty { Text("No songs to show yet.").foregroundStyle(VesperTheme.muted) }
            ForEach(catalog.collection["tracks"].array) { track in
                HStack {
                    Button { Task { await catalog.prepare([track], store: store, player: player, append: true) } } label: { MusicTrackRow(track: track, active: player.track.id == track.id) }.buttonStyle(.plain)
                    addToPlaylist(track)
                    Button { Task { await catalog.prepare([track], store: store, player: player, append: true, autoplay: false) } } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Add to queue")
                }.disabled(catalog.busy)
            }
        }
    }
}
