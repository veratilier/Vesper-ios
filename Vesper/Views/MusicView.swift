import SwiftUI
import MusicKit
import MediaPlayer
import AVKit
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

/// The music destination is for finding something to play. The full player
/// remains a separate sheet so the same queue survives navigation.
struct MusicView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var catalog = MusicCatalog()
    var openPlayer: () -> Void = {}

    var body: some View {
        MusicLibraryView(catalog: catalog, embedded: true)
            .safeAreaInset(edge: .bottom, spacing: 6) {
                if !VesperLayout.usesSidebar {
                    MiniMusicPlayer(openMusic: openPlayer)
                }
            }
            .task {
                player.configure(store)
                player.updateLibrary(store.document("music").array)
            }
            .onChange(of: store.document("music")) { _, value in
                player.updateLibrary(value.array)
            }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
private struct MusicVolumeControl: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // Leave system volume presentation to MPVolumeView. Its route-button
        // customization API is deprecated; our output picker uses AVRoutePickerView.
        view.showsVolumeSlider = true
        view.tintColor = .white
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
private struct MusicRouteControl: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .white
        view.activeTintColor = .white
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

struct MusicNowPlayingView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog = MusicCatalog()
    @State private var showingLibrary = false
    @State private var page: PlayerPage

    private enum PlayerPage { case artwork, lyrics, queue }
    init(showingLyrics: Bool = false) {
        _page = State(initialValue: showingLyrics ? .lyrics : .artwork)
    }
    #if DEBUG
    private var dockObserver: ((CGRect) -> Void)?
    init(showingLyrics: Bool, observeDock: @escaping (CGRect) -> Void) {
        _page = State(initialValue: showingLyrics ? .lyrics : .artwork)
        dockObserver = observeDock
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                #if targetEnvironment(macCatalyst)
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                        .accessibilityLabel("Minimize player")
                    Spacer()
                }
                #endif
                Group {
                    switch page {
                    case .artwork: artworkPage(in: geometry.size)
                    case .lyrics: lyricsPage
                    case .queue: queuePage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                VStack(spacing: 20) {
                    progress
                    transport
                    volume
                    pageControls
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("music-playback-dock")
                #if DEBUG
                .background {
                    if let dockObserver {
                        GeometryReader { area in
                            let frame = area.frame(in: .global)
                            Color.clear.onAppear { dockObserver(frame) }
                                .onChange(of: frame) { _, value in dockObserver(value) }
                        }
                    }
                }
                #endif
            }
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 22)
        }
        .background { backdrop }
        .preferredColorScheme(.dark)
        .foregroundStyle(.white)
        .tint(.white)
        .buttonStyle(.plain)
        .task {
            player.configure(store)
            player.updateLibrary(store.document("music").array)
        }
        .onChange(of: store.document("music")) { _, value in player.updateLibrary(value.array) }
        .sheet(isPresented: $showingLibrary) {
            MusicLibraryView(catalog: catalog)
                .environmentObject(store).environmentObject(player)
                .preferredColorScheme(VesperTheme.palette == .black ? .dark : .light)
        }
        .alert("Music", isPresented: Binding(get: { player.error != nil },
                                              set: { if !$0 { player.error = nil } })) {
            Button("OK") { player.error = nil }
        } message: { Text(player.error ?? "") }
    }

    private var backdrop: some View {
        GeometryReader { area in
            let side = max(area.size.width, area.size.height)
            Artwork(url: player.track["cover"].string)
                .frame(width: side, height: side)
                .scaleEffect(1.25)
                .frame(width: area.size.width, height: area.size.height)
                .blur(radius: 72)
                .overlay(Color.black.opacity(0.53))
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.38)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
        }
        .ignoresSafeArea()
    }

    private func artworkPage(in available: CGSize) -> some View {
        let size = max(120, min(available.width - 56, available.height * 0.48, 460))
        return VStack(spacing: 0) {
            Spacer(minLength: 12)
            NowPlayingArtwork(artwork: player.currentArtwork,
                              url: player.track["cover"].string, size: size)
                .shadow(color: .black.opacity(0.24), radius: 22, y: 14)
            Spacer(minLength: 26)
            trackCopy
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var trackCopy: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string)
                    .font(.system(size: 22, weight: .bold)).lineLimit(1)
                Text(player.track["artist"].string)
                    .font(.system(size: 17, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 4)
            Button {
                Task { await toggleFavorite() }
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 24)).frame(width: 44, height: 44)
            }
            .disabled(player.track.id.isEmpty)
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            Menu {
                Button("Browse music", systemImage: "music.note.list") { showingLibrary = true }
                if let url = URL(string: player.track["appleMusicURL"].string), url.scheme == "https" {
                    ShareLink(item: url) { Label("Share song", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 23))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("More music options")
        }
    }
    private var isFavorite: Bool {
        store.document("musicFavorites").array.contains { $0.id == player.track.id && !player.track.id.isEmpty }
    }
    private func toggleFavorite() async {
        let selected = player.track
        guard !selected.id.isEmpty else { return }
        _ = await store.mutate("musicFavorites") { current in
            var values = current.array
            if let index = values.firstIndex(where: { $0.id == selected.id }) { values.remove(at: index) }
            else { values.append(selected) }
            return .array(values)
        }
    }

    private var lyricsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            compactTrackHeader
            ScrollViewReader { proxy in
                GeometryReader { pane in
                    ScrollView {
                        let lines = player.lyrics
                        if player.lyricsLoading {
                            ProgressView("Finding lyrics…")
                                .tint(.white)
                                .frame(maxWidth: .infinity, minHeight: pane.size.height)
                        } else if lines.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Lyrics aren't available for this version.")
                                    .font(.system(size: 28, weight: .bold))
                                if let url = URL(string: player.track["appleMusicURL"].string),
                                   url.scheme == "https" {
                                    Link("Open in Apple Music", destination: url)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: pane.size.height, alignment: .leading)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 28) {
                                Color.clear.frame(height: pane.size.height * 0.3)
                                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                    let distance = abs(index - currentLyricIndex)
                                    Button {
                                        player.seek(line["time"].number)
                                    } label: {
                                        Text(line["text"].string)
                                            .font(.system(size: 30, weight: .bold))
                                            .foregroundStyle(.white.opacity(distance == 0 ? 1 : index < currentLyricIndex ? 0.48 : 0.38))
                                            .blur(radius: distance == 0 ? 0 : distance == 1 ? 0.7 : 1.4)
                                            .scaleEffect(distance == 0 ? 1 : 0.97, anchor: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .accessibilityHint("Play from this lyric")
                                    .id(index)
                                }
                                Color.clear.frame(height: pane.size.height * 0.55)
                            }
                            .animation(.easeInOut(duration: 0.55), value: currentLyricIndex)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .white, location: 0.09),
                            .init(color: .white, location: 0.86),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .task(id: "\(player.track.id):\(player.lyrics.count)") {
                        await Task.yield()
                        proxy.scrollTo(currentLyricIndex, anchor: .center)
                    }
                    .onChange(of: currentLyricIndex) { _, index in
                        withAnimation(.easeInOut(duration: 0.7)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
    }
    private var currentLyricIndex: Int {
        player.lyrics.indices.last { player.lyrics[$0]["time"].number <= player.position } ?? 0
    }

    private var queuePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            compactTrackHeader
            HStack {
                Text("Playing Next").font(.system(size: 23, weight: .bold))
                Spacer()
                Button {
                    player.setMode(player.mode == "random" ? "order" : "random")
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.mode == "random" ? .white : .white.opacity(0.55))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.mode == "random" ? "Turn shuffle off" : "Turn shuffle on")
                Button {
                    player.setMode(player.mode == "repeat" ? "single" : player.mode == "single" ? "order" : "repeat")
                } label: {
                    Image(systemName: player.mode == "single" ? "repeat.1" : "repeat")
                        .foregroundStyle(player.mode == "repeat" || player.mode == "single" ? .white : .white.opacity(0.55))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Repeat mode")
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if upcomingTracks.isEmpty {
                        Text("Nothing else in the queue.")
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    ForEach(upcomingTracks) { track in
                        Button { player.select(track) } label: {
                            HStack(spacing: 12) {
                                if let artwork = player.artwork(for: track) {
                                    MusicKit.ArtworkImage(artwork, width: 48, height: 48)
                                } else {
                                    Artwork(url: track["cover"].string).frame(width: 48, height: 48)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track["title"].string).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                                    Text(track["artist"].string).font(.caption)
                                        .foregroundStyle(.white.opacity(0.64)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(height: 54)
                        }
                        .task(id: track["appleMusicId"].string) { await player.ensureArtwork(for: track) }
                    }
                }
            }
        }
    }
    private var upcomingTracks: [JSONValue] {
        guard let index = player.tracks.firstIndex(where: { $0.id == player.track.id }) else {
            return player.tracks
        }
        return Array(player.tracks.dropFirst(index + 1))
    }
    private var compactTrackHeader: some View {
        HStack(spacing: 12) {
            NowPlayingArtwork(artwork: player.currentArtwork,
                              url: player.track["cover"].string, size: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text(player.track["title"].string).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(player.track["artist"].string).font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
    }

    private var progress: some View {
        VStack(spacing: 2) {
            Slider(value: Binding(get: { min(player.position, max(1, player.duration)) },
                                  set: { player.seek($0) }),
                   in: 0...max(1, player.duration))
                .disabled(player.duration <= 0)
                .tint(.white)
                .accessibilityLabel("Playback position")
            HStack {
                Text(time(player.position))
                Spacer()
                Text(player.duration > 0 ? "−" + time(max(0, player.duration - player.position)) : "--:--")
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.66))
        }
    }
    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("backward.end.fill", label: "Previous song", size: 32) { player.next(-1) }
            Button { player.toggle() } label: {
                Group {
                    if player.resolving { ProgressView().tint(.white) }
                    else {
                        Image(systemName: player.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 48, weight: .regular))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 76)
            }
            .disabled(player.tracks.isEmpty || player.resolving)
            .accessibilityLabel(player.playing ? "Pause" : "Play")
            transportButton("forward.end.fill", label: "Next song", size: 32) { player.next(1) }
        }
    }
    private func transportButton(_ icon: String, label: String, size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size))
                .frame(maxWidth: .infinity).frame(height: 76)
        }
        .disabled(player.tracks.isEmpty || player.resolving)
        .accessibilityLabel(label)
    }
    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.system(size: 13))
            #if os(iOS) && !targetEnvironment(macCatalyst)
            MusicVolumeControl().frame(height: 30)
            #else
            Spacer()
            #endif
            Image(systemName: "speaker.wave.3.fill").font(.system(size: 15))
        }
        .foregroundStyle(.white.opacity(0.78))
        .accessibilityElement(children: .contain)
    }
    private var pageControls: some View {
        HStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.22)) { page = page == .lyrics ? .artwork : .lyrics } } label: {
                Image(systemName: page == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                    .frame(maxWidth: .infinity).frame(height: 50)
            }
            .accessibilityLabel(page == .lyrics ? "Show artwork" : "Show lyrics")
            Group {
                #if os(iOS) && !targetEnvironment(macCatalyst)
                MusicRouteControl()
                    .frame(width: 42, height: 42)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Audio output")
                #else
                Image(systemName: "airplay.audio")
                    .frame(maxWidth: .infinity).frame(height: 50)
                #endif
            }
            Button { withAnimation(.easeInOut(duration: 0.22)) { page = page == .queue ? .artwork : .queue } } label: {
                Image(systemName: page == .queue ? "list.bullet.circle.fill" : "list.bullet")
                    .frame(maxWidth: .infinity).frame(height: 50)
            }
            .accessibilityLabel(page == .queue ? "Show artwork" : "Show queue")
        }
        .font(.system(size: 21))
        .foregroundStyle(.white.opacity(0.82))
    }
    private func time(_ seconds: Double) -> String {
        guard player.duration > 0 else { return "--:--" }
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
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
    var embedded = false
    #if DEBUG
    var preview = false
    #endif
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var showingSearch = false
    @State private var query = ""
    @State private var category: Category?
    @State private var selectedVesperPlaylistID: String?
    @State private var creatingPlaylist = false
    @State private var playlistName = ""
    @State private var playlistToRename: JSONValue = .null
    @State private var renamedPlaylistName = ""
    @State private var playlistToDelete: JSONValue = .null
    @State private var playlistBusy = false
    @State private var showingPlaylistSongPicker = false
    @State private var songQuery = ""
    @State private var removalTrack: JSONValue = .null

    private enum Category: String {
        case playlists = "Playlists", artists = "Artists", albums = "Albums", favorites = "Favorites"
    }
    private var savedPlaylists: [JSONValue] { store.document("musicPlaylists").array }
    private var selectedVesperPlaylist: JSONValue? {
        savedPlaylists.first { $0.id == selectedVesperPlaylistID }
    }
    private var hasInnerPage: Bool {
        selectedVesperPlaylistID != nil || catalog.collection != .null || category != nil || showingSearch
    }
    private func goBack() {
        if selectedVesperPlaylistID != nil { selectedVesperPlaylistID = nil }
        else if catalog.collection != .null { catalog.collection = .null }
        else if category != nil { category = nil }
        else { showingSearch = false }
    }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let playlist = selectedVesperPlaylist { vesperDetail(playlist) }
                else if catalog.collection != .null { collectionDetail }
                else if category == .favorites { favoriteDetail }
                else if let category { categoryPage(category) }
                else if showingSearch { searchPage }
                else { libraryHome }
                if !catalog.message.isEmpty {
                    Text(catalog.message).font(.caption).foregroundStyle(VesperTheme.muted)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, hasInnerPage ? 24 : 4)
            .padding(.bottom, 28)
        }
        .background { Background() }
        .navigationTitle("Music")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasInnerPage)
        .toolbar {
            if hasInnerPage {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Back to music library")
                }
            }
            if !hasInnerPage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSearch = true } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search music")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if catalog.connected { await catalog.refresh(player: player) }
                        else { await catalog.connect(player: player) }
                    }
                } label: {
                    if catalog.busy { ProgressView() }
                    else {
                        Image(systemName: catalog.connected ? "checkmark.circle.fill" : "music.note")
                            .foregroundStyle(catalog.connected ? Color.green : VesperTheme.ink)
                    }
                }
                .disabled(catalog.busy)
                .accessibilityLabel(catalog.connected ? "Refresh Apple Music library" : "Connect Apple Music")
            }
            if !embedded {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .alert("New Vesper playlist", isPresented: $creatingPlaylist) {
            TextField("Playlist name", text: $playlistName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await playlistTool("music_playlist_create", arguments: .object([
                        "name": .string(name), "requestId": .string(UUID().uuidString)
                    ]))
                }
            }.disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || playlistName.count > 100)
        }
        .alert("Rename Vesper playlist", isPresented: Binding(
            get: { playlistToRename != .null },
            set: { if !$0 { playlistToRename = .null } }
        )) {
            TextField("Playlist name", text: $renamedPlaylistName)
            Button("Cancel", role: .cancel) { playlistToRename = .null }
            Button("Save") {
                let id = playlistToRename.id
                let name = renamedPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                playlistToRename = .null
                Task { await playlistTool("music_playlist_rename", arguments: .object([
                    "playlistId": .string(id), "name": .string(name)
                ])) }
            }.disabled(renamedPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedPlaylistName.count > 100)
        }
        .confirmationDialog("Delete \(playlistToDelete["name"].string)?",
                            isPresented: Binding(get: { playlistToDelete != .null },
                                                 set: { if !$0 { playlistToDelete = .null } })) {
            Button("Delete Playlist", role: .destructive) {
                let id = playlistToDelete.id
                playlistToDelete = .null
                Task {
                    if await playlistTool("music_playlist_delete", arguments: .object(["playlistId": .string(id)])),
                       selectedVesperPlaylistID == id { selectedVesperPlaylistID = nil }
                }
            }
        } message: {
            Text("The songs stay in your music library and current playback queue.")
        }
        .sheet(isPresented: $showingPlaylistSongPicker) { playlistSongPicker }
        .confirmationDialog("Remove from Vesper playlist?",
                            isPresented: Binding(get: { removalTrack != .null },
                                                 set: { if !$0 { removalTrack = .null } })) {
            if let playlistID = selectedVesperPlaylistID, !removalTrack.id.isEmpty {
                Button("Remove Song", role: .destructive) {
                    let trackID = removalTrack.id
                    removalTrack = .null
                    Task {
                        await playlistTool("music_playlist_remove", arguments: .object([
                            "playlistId": .string(playlistID), "trackId": .string(trackID)
                        ]))
                    }
                }
            }
        } message: {
            Text("The song stays in your music library and current playback queue.")
        }
        .task {
            #if DEBUG
            if preview { return }
            #endif
            await refreshPlaylists()
            catalog.connected = MusicAuthorization.currentStatus == .authorized
            if catalog.connected { await catalog.refresh(player: player) }
        }
    }

    private var libraryHome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                categoryRow("Playlists", icon: "music.note.list", category: .playlists)
                divider
                categoryRow("Artists", icon: "music.mic", category: .artists)
                divider
                categoryRow("Albums", icon: "square.stack", category: .albums)
                divider
                Button {
                    Task { await catalog.mySongs(player: player) }
                } label: {
                    categoryLabel("Songs", icon: "music.note")
                }
                .buttonStyle(.plain)
                .disabled(!catalog.connected || catalog.busy)
                divider
                categoryRow("Favorites", icon: "star", category: .favorites)
            }

            recentGrid
        }
    }

    private var divider: some View {
        Rectangle().fill(VesperTheme.ink.opacity(0.12)).frame(height: 0.5).padding(.leading, 40)
    }
    private func categoryLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 24)
            Text(title).font(.system(size: 17, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VesperTheme.muted)
        }
        .foregroundStyle(VesperTheme.ink)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
    private func categoryRow(_ title: String, icon: String, category destination: Category) -> some View {
        Button {
            category = destination
            if destination == .artists || destination == .albums {
                Task { await catalog.loadAllSongs(player: player) }
            }
        } label: { categoryLabel(title, icon: icon) }
            .buttonStyle(.plain)
    }

    private var recentGrid: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recently Added").font(.system(size: 26, weight: .bold))
                .foregroundStyle(VesperTheme.ink)
            if catalog.recentSongs.isEmpty {
                Text(catalog.connected ? "Your music will appear here." : "Connect Apple Music to see your library.")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                          alignment: .leading, spacing: 22) {
                    ForEach(recentAlbums, id: \.key) { item in
                        Button {
                            catalog.collection = .object([
                                "title": .string(item.key),
                                "tracks": .array(item.tracks)
                            ])
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                GeometryReader { area in
                                    musicArtwork(item.tracks[0], size: area.size.width)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                .aspectRatio(1, contentMode: .fit)
                                Text(item.key).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                Text(item.tracks[0]["artist"].string).font(.caption)
                                    .foregroundStyle(VesperTheme.muted).lineLimit(1)
                            }
                            .foregroundStyle(VesperTheme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var recentAlbums: [(key: String, tracks: [JSONValue])] {
        let songs = catalog.recentSongs
        var seen = Set<String>()
        return songs.compactMap { track -> (key: String, tracks: [JSONValue])? in
            let album = track["album"].string
            let key = album.isEmpty ? track["title"].string : album
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return (key, songs.filter {
                let value = $0["album"].string
                return (value.isEmpty ? $0["title"].string : value) == key
            })
        }.prefix(12).map { $0 }
    }
    private func musicArtwork(_ track: JSONValue, size: CGFloat) -> some View {
        Group {
            if let artwork = player.artwork(for: track) {
                MusicKit.ArtworkImage(artwork, width: size, height: size)
            } else { Artwork(url: track["cover"].string) }
        }
        .frame(width: size, height: size)
        .clipped()
        .task(id: track["appleMusicId"].string) { await player.ensureArtwork(for: track) }
    }

    @ViewBuilder private func categoryPage(_ selected: Category) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(selected.rawValue).font(.system(size: 34, weight: .bold))
                .foregroundStyle(VesperTheme.ink)
            if selected == .playlists { playlistBrowser }
            else { groupBrowser(selected) }
        }
    }
    private var playlistBrowser: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Vesper playlists").font(.headline)
                    Spacer()
                    Button { playlistName = ""; creatingPlaylist = true } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Create Vesper playlist")
                }
                if savedPlaylists.isEmpty {
                    Text("Your Vesper playlists will appear here.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                ForEach(savedPlaylists) { playlist in
                    HStack(spacing: 0) {
                        Button { selectedVesperPlaylistID = playlist.id } label: {
                            playlistRow(playlist["name"].string,
                                        subtitle: "\(playlist["tracks"].array.count) songs",
                                        cover: ChatMusicShare.coverURL(playlist["tracks"].array.first ?? .null),
                                        showsChevron: false)
                        }
                        .buttonStyle(.plain)
                        playlistMenu(playlist)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Apple Music").font(.headline)
                if catalog.playlists.isEmpty {
                    Text("Your Apple Music playlists will appear here.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                ForEach(catalog.playlists) { playlist in
                    Button {
                        Task { await catalog.playlist(playlist.id, player: player) }
                    } label: {
                        playlistRow(playlist["name"].string, subtitle: "Playlist",
                                    cover: playlist["cover"].string,
                                    nativeArtwork: catalog.artwork(for: playlist))
                    }
                    .buttonStyle(.plain)
                    .task(id: playlist.id) {
                        await catalog.ensurePlaylistArtwork(for: playlist.id, player: player)
                    }
                }
            }
        }
        .foregroundStyle(VesperTheme.ink)
    }
    private func playlistRow(_ title: String, subtitle: String, cover: String,
                             nativeArtwork: MusicKit.Artwork? = nil,
                             showsChevron: Bool = true) -> some View {
        HStack(spacing: 13) {
            Group {
                if let nativeArtwork {
                    MusicKit.ArtworkImage(nativeArtwork, width: 58, height: 58)
                } else { Artwork(url: cover) }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Spacer(minLength: 6)
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(VesperTheme.muted)
            }
        }
        .frame(minHeight: 88)
        .overlay(alignment: .bottom) {
            Rectangle().fill(VesperTheme.ink.opacity(0.13))
                .frame(height: 0.5).padding(.leading, 71)
        }
    }
    private func playlistMenu(_ playlist: JSONValue) -> some View {
        Menu {
            Button("Rename", systemImage: "pencil") {
                renamedPlaylistName = playlist["name"].string
                playlistToRename = playlist
            }
            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                playlistToDelete = playlist
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(playlistBusy)
        .accessibilityLabel("Manage \(playlist["name"].string) playlist")
    }
    private func groupBrowser(_ selected: Category) -> some View {
        let key = selected == .artists ? "artist" : "album"
        let names = Set(catalog.songs.map { $0[key].string }.filter { !$0.isEmpty }).sorted()
        return VStack(spacing: 0) {
            if names.isEmpty {
                Text("No \(selected.rawValue.lowercased()) found in your library.")
                    .foregroundStyle(VesperTheme.muted)
            }
            ForEach(names, id: \.self) { name in
                Button {
                    catalog.collection = .object([
                        "title": .string(name),
                        "tracks": .array(catalog.songs.filter { $0[key].string == name })
                    ])
                } label: {
                    playlistRow(name, subtitle: selected.rawValue.dropLast().description,
                                cover: catalog.songs.first { $0[key].string == name }?["cover"].string ?? "")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var searchPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Search").font(.system(size: 34, weight: .bold))
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                TextField("Songs, artists or albums", text: $query)
                    .submitLabel(.search).onSubmit(searchSongs)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(14)
            .background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            Button(action: searchSongs) {
                Text(catalog.busy ? "Searching…" : "Search Apple Music")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(VesperTheme.surface, in: Capsule())
            }
            .disabled(catalog.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .foregroundStyle(VesperTheme.ink)
    }
    private func searchSongs() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { await catalog.search(query, api: store.api) }
    }

    private func vesperDetail(_ playlist: JSONValue) -> some View {
        collectionBody(title: playlist["name"].string,
                       tracks: playlist["tracks"].array,
                       cover: ChatMusicShare.coverURL(playlist["tracks"].array.first ?? .null),
                       playlistID: playlist.id,
                       playAll: {
                           Task {
                               await playlistTool("music_playlist_play",
                                                  arguments: .object(["playlistId": .string(playlist.id)]),
                                                  playback: true)
                           }
                       })
    }
    private var favoriteDetail: some View {
        let tracks = store.document("musicFavorites").array
        return Group {
            if tracks.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "star")
                        .font(.system(size: 44))
                        .foregroundStyle(VesperTheme.muted)
                    Text("Favorites").font(.system(size: 34, weight: .bold))
                    Text("Tap the star in the player to save songs here.")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                .padding(.top, 40)
            } else {
                collectionBody(title: "Favorite Songs", tracks: tracks,
                               cover: tracks.first?["cover"].string ?? "",
                               isFavorites: true,
                               playAll: {
                                   Task { await catalog.prepare(tracks, store: store, player: player) }
                               })
            }
        }
    }
    private var collectionDetail: some View {
        let tracks = catalog.collection["tracks"].array
        return collectionBody(title: catalog.collection["title"].string.isEmpty
                                   ? "Songs" : catalog.collection["title"].string,
                              tracks: tracks,
                              cover: tracks.first?["cover"].string ?? "",
                              playAll: {
                                  Task { await catalog.prepare(tracks, store: store, player: player) }
                              })
    }
    private func collectionBody(title: String, tracks: [JSONValue], cover: String,
                                playlistID: String? = nil,
                                isFavorites: Bool = false,
                                playAll: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 16) {
                Artwork(url: cover)
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.16), radius: 16, y: 9)
                HStack {
                    if let playlistID, let playlist = savedPlaylists.first(where: { $0.id == playlistID }) {
                        Color.clear.frame(width: 44, height: 44)
                        Text(title).font(.system(size: 29, weight: .bold))
                            .multilineTextAlignment(.center).lineLimit(3)
                            .frame(maxWidth: .infinity)
                        playlistMenu(playlist)
                    } else {
                        Text(title).font(.system(size: 29, weight: .bold))
                            .multilineTextAlignment(.center).lineLimit(3)
                            .frame(maxWidth: .infinity)
                    }
                }
                Text("\(tracks.count) songs")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            HStack(spacing: 12) {
                Button {
                    Task { await catalog.prepare(tracks.shuffled(), store: store, player: player) }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(VesperTheme.surface, in: Capsule())
                }
                Button(action: playAll) {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(VesperTheme.surface, in: Capsule())
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .disabled(tracks.isEmpty || catalog.busy)
            if playlistID != nil {
                Button {
                    songQuery = ""
                    showingPlaylistSongPicker = true
                } label: {
                    Label("Add Songs", systemImage: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .disabled(playlistBusy)
                .accessibilityLabel("Add songs to Vesper playlist")
            }
            if tracks.isEmpty {
                Text("No songs to show yet.").foregroundStyle(VesperTheme.muted)
            }
            LazyVStack(spacing: 0) {
                ForEach(tracks) { track in
                    HStack(spacing: 0) {
                        Button {
                            Task { await catalog.prepare([track], store: store, player: player, append: true) }
                        } label: {
                            MusicTrackRow(track: track, active: player.track.id == track.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            if isFavorites {
                                Button("Remove from Favorites", systemImage: "star.slash", role: .destructive) {
                                    Task { await removeFavorite(track) }
                                }
                            }
                            if playlistID != nil {
                                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                                    removalTrack = track
                                }
                            }
                            Button("Queue playlist", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                Task { await catalog.prepare(tracks, store: store, player: player,
                                                             autoplay: false) }
                            }
                            Button("Add to queue", systemImage: "text.badge.plus") {
                                Task { await catalog.prepare([track], store: store, player: player,
                                                             append: true, autoplay: false) }
                            }
                            ForEach(savedPlaylists) { playlist in
                                Button("Add to \(playlist["name"].string)") {
                                    Task { await addTrack(track, to: playlist.id) }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("More options for \(track["title"].string)")
                    }
                    .frame(minHeight: 64)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(VesperTheme.ink.opacity(0.13))
                            .frame(height: 0.5).padding(.leading, 56)
                    }
                }
            }
        }
        .foregroundStyle(VesperTheme.ink)
    }

    private var pickerTracks: [JSONValue] {
        let all = catalog.songs + store.document("music").array
        var seen = Set<String>()
        let unique = all.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        let term = songQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return unique }
        return unique.filter {
            $0["title"].string.localizedCaseInsensitiveContains(term) ||
            $0["artist"].string.localizedCaseInsensitiveContains(term)
        }
    }

    private var playlistSongPicker: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                    TextField("Search songs or artists", text: $songQuery)
                        .autocorrectionDisabled()
                }
                .padding(13)
                .background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                if pickerTracks.isEmpty {
                    ContentUnavailableView(catalog.busy ? "Loading Songs" : "No Songs Found",
                                           systemImage: "music.note")
                } else {
                    List(pickerTracks) { track in
                        let alreadyAdded = selectedVesperPlaylist?["tracks"].array.contains {
                            $0.id == track.id || (!$0["appleMusicId"].string.isEmpty &&
                                                  $0["appleMusicId"].string == track["appleMusicId"].string)
                        } ?? false
                        Button {
                            guard let playlistID = selectedVesperPlaylistID else { return }
                            Task { await addTrack(track, to: playlistID) }
                        } label: {
                            HStack {
                                MusicTrackRow(track: track)
                                Image(systemName: alreadyAdded ? "checkmark" : "plus.circle.fill")
                                    .foregroundStyle(alreadyAdded ? VesperTheme.muted : VesperTheme.ink)
                            }
                        }
                        .disabled(alreadyAdded || playlistBusy)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background { Background() }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingPlaylistSongPicker = false }
                }
            }
            .task {
                if catalog.connected { await catalog.loadAllSongs(player: player) }
            }
        }
        .foregroundStyle(VesperTheme.ink)
    }

    private func addTrack(_ track: JSONValue, to playlistID: String) async {
        guard await store.upsert("music", item: track) else {
            catalog.message = "Could not save this song for the playlist."
            return
        }
        await playlistTool("music_playlist_add", arguments: .object([
            "playlistId": .string(playlistID), "trackId": .string(track.id)
        ]))
    }

    private func removeFavorite(_ track: JSONValue) async {
        let saved = await store.mutate("musicFavorites") { current in
            .array(current.array.filter { $0.id != track.id })
        }
        if !saved { catalog.message = "Could not remove this favorite. Try again." }
    }

    private func refreshPlaylists() async {
        do {
            let result = try await store.api.request("/api/codex/tools", method: "POST",
                body: .object(["name": .string("music_playlist_list"), "arguments": .object([:])]))
            store.documents["musicPlaylists"] = result["result"]["playlists"]
        } catch { catalog.message = error.localizedDescription }
    }
    @discardableResult private func playlistTool(_ name: String, arguments: JSONValue, playback: Bool = false) async -> Bool {
        guard !playlistBusy else { return false }
        playlistBusy = true
        defer { playlistBusy = false }
        do {
            let response = try await store.api.request("/api/codex/tools", method: "POST",
                body: .object(["name": .string(name), "arguments": arguments]))
            if playback {
                let result = await player.applyControl(response["result"]["command"])
                if !result["pending"].bool && !result["applied"].bool {
                    throw ServiceError(message: result["error"].string)
                }
            }
            await refreshPlaylists()
            return true
        } catch {
            catalog.message = error.localizedDescription
            return false
        }
    }
}
