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
    @State private var showingLyrics = false
    @AppStorage("music.lyricsFrostedBackground") private var lyricsFrostedBackground = true
    private enum MusicSheet: String, Identifiable { case library, queue; var id: String { rawValue } }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button { player.cycleMode() } label: {
                            Image(systemName: playbackModeIcon)
                                .font(.system(size: 19))
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Playback mode: \(playbackModeName). Tap to change")
                        Button { sheet = .library } label: {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 19))
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().stroke(VesperTheme.accent.opacity(0.25)))
                        }
                        .accessibilityLabel("My Music")
                    }
                    let artworkSize = max(220, min(geometry.size.width - 52, 460))
                    let lyricsHeight = max(artworkSize + 100, min(geometry.size.height - 210, 650))
                    TabView(selection: $showingLyrics) {
                        NowPlayingArtwork(artwork: player.currentArtwork,
                                          url: player.track["cover"].string, size: artworkSize)
                            .tag(false)
                        lyricsPanel.tag(true)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: artworkSize, height: showingLyrics ? lyricsHeight : artworkSize)
                    .padding(.vertical, 8)
                    .accessibilityHint("Swipe sideways to switch between the album cover and lyrics")
                    if !showingLyrics { trackCopy }
                    progress
                    controls
                }.padding(.horizontal, 26).padding(.top, 4).padding(.bottom, 40)
                    .frame(maxWidth: 580).frame(maxWidth: .infinity)
            }
        }
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
                    RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
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
        HStack(spacing: 0) {
            control(showingLyrics ? "quote.bubble.fill" : "quote.bubble", label: showingLyrics ? "Show album cover" : "Show lyrics") {
                withAnimation(.easeInOut(duration: 0.25)) { showingLyrics.toggle() }
            }
            Spacer(minLength: 5)
            control("backward.end", label: "Previous song") { player.next(-1) }
            Spacer(minLength: 5)
            Button { player.toggle() } label: {
                Group { if player.resolving { ProgressView() } else { Image(systemName: player.playing ? "pause" : "play").font(.system(size: 29)) } }
                    .frame(width: 68, height: 68).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.6)))
            }.disabled(player.tracks.isEmpty || player.resolving).accessibilityLabel(player.playing ? "Pause" : "Play")
            Spacer(minLength: 5)
            control("forward.end", label: "Next song") { player.next(1) }
            Spacer(minLength: 5)
            control("text.line.first.and.arrowtriangle.forward", label: "Queue, \(player.tracks.count) songs") { sheet = .queue }
                .overlay(alignment: .topTrailing) { Text("\(player.tracks.count)").font(.system(size: 9)).foregroundStyle(VesperTheme.muted).allowsHitTesting(false) }
        }.padding(.vertical, 4)
    }
    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 21)).frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle()).overlay(Circle().stroke(.white.opacity(0.6))) }.accessibilityLabel(label)
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

private struct MusicLibraryView: View {
    @ObservedObject var catalog: MusicCatalog
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "mine"
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(VesperTheme.muted) }
                if catalog.collection != .null { collection }
                else {
                    Picker("Music", selection: $tab) { Text("My Music").tag("mine"); Text("Discover").tag("discover") }.pickerStyle(.segmented)
                    if tab == "mine" {
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
                .task {
                    catalog.connected = MusicAuthorization.currentStatus == .authorized
                    if catalog.connected { await catalog.refresh(player: player) }
                }
        }.presentationDragIndicator(.visible)
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
                    Button { Task { await catalog.prepare([track], store: store, player: player, append: true, autoplay: false) } } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.buttonStyle(.borderless).accessibilityLabel("Add to queue")
                }.disabled(catalog.busy)
            }
        }
    }
}
