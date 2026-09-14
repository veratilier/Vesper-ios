import SwiftUI
struct Artwork: View {
    let url: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack { VesperTheme.accent.opacity(0.2); Image(systemName: "music.note").font(.largeTitle).foregroundStyle(VesperTheme.muted) }
        }.clipped()
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
    private enum MusicSheet: String, Identifiable { case library, queue; var id: String { rawValue } }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    HStack { Spacer(); Button { sheet = .library } label: { Label("My Music", systemImage: "books.vertical").font(.system(size: 14, weight: .medium)).padding(.horizontal, 16).frame(height: 42).background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().stroke(VesperTheme.accent.opacity(0.25))) } }
                    together
                    Artwork(url: player.track["cover"].string).id(player.track.id + player.track["cover"].string)
                        .frame(width: max(180, min(geometry.size.width - 88, 340)), height: max(180, min(geometry.size.width - 88, 340)))
                        .clipShape(Circle()).overlay(Circle().stroke(VesperTheme.accent.opacity(0.6), lineWidth: 5))
                        .padding(.vertical, 2)
                    trackCopy
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
    private var together: some View {
        Button {
            Task { _ = await store.mutate("musicTogether") { current in
                guard current["status"].string != "connected" else { return current }
                var next = current; next["status"] = .string("invited"); next["inviteRequestedAt"] = .string(isoNow()); next["updatedAt"] = .string(isoNow()); return next
            } }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 4) { avatar("user"); avatar("agent") }
                TimelineView(.periodic(from: .now, by: 60)) { timeline in Text(togetherLabel(timeline.date)).font(.system(size: 13)).foregroundStyle(VesperTheme.muted) }
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.saving || store.document("musicTogether")["status"].string == "connected")
    }
    private func avatar(_ role: String) -> some View {
        let source = store.document("profile")["\(role)Avatar"].string
        return Group {
            if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","), let data = Data(base64Encoded: String(source[source.index(after: comma)...])), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !source.isEmpty, let url = URL(string: source, relativeTo: URL(string: store.baseURL))?.absoluteURL, url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { avatarPlaceholder }
            } else { avatarPlaceholder }
        }.frame(width: 44, height: 44).clipShape(Circle()).overlay(Circle().stroke(.white.opacity(0.65)))
    }
    private var avatarPlaceholder: some View { LinearGradient(colors: [.gray.opacity(0.8), .white.opacity(0.5)], startPoint: .top, endPoint: .bottom) }
    private func togetherLabel(_ now: Date) -> String {
        let state = store.document("musicTogether")
        switch state["status"].string {
        case "connected":
            let started = ISO8601DateFormatter().date(from: state["sessionStartedAt"].string)
            let seconds = max(0, state["totalListeningSeconds"].number) + (started.map { max(0, now.timeIntervalSince($0)) } ?? 0)
            return "Listening together for \(Int(seconds) / 3600)h \(Int(seconds) % 3600 / 60)m"
        case "invited": return "Listen-together invitation sent"
        case "offline": return "The other listener is offline."
        default: return "Invite to listen together"
        }
    }
    private var trackCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(player.track["title"].string.isEmpty ? "Your next song" : player.track["title"].string).font(.system(size: 25, weight: .semibold)).lineLimit(2)
            Text([player.track["artist"].string, player.track["album"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 14)).foregroundStyle(VesperTheme.muted).lineLimit(2)
            if player.track == .null { Text("Open My Music to connect NetEase or search for songs.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
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
            control(modeIcon, label: "Playback mode: \(player.mode)") { player.cycleMode() }
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
    private var modeIcon: String { switch player.mode { case "repeat": return "repeat"; case "single": return "repeat.1"; case "random": return "shuffle"; default: return "line.3.horizontal" } }
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
    let track: JSONValue
    var active = false
    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: track["cover"].string).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) { Text(track["title"].string).font(.system(size: 15, weight: .medium)).lineLimit(2); Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1) }
            Spacer(minLength: 4)
            if active { Image(systemName: "waveform").foregroundStyle(VesperTheme.accent) }
        }.foregroundStyle(VesperTheme.ink).padding(.vertical, 3).contentShape(Rectangle())
    }
}

private struct MusicLibraryView: View {
    @ObservedObject var catalog: MusicCatalog
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var accountOpen = false
    @State private var tab = "mine"
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                if catalog.busy { ProgressView("Loading music…") }
                if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(VesperTheme.muted) }
                if catalog.collection != .null { collection }
                else {
                    Picker("Music", selection: $tab) { Text("My Music").tag("mine"); Text("Discover").tag("discover") }.pickerStyle(.segmented)
                    if tab == "mine" { account; shortcuts; playlists }
                    else { search; shortcuts }
                }
            }.scrollContentBackground(.hidden).background { Background() }
                .navigationTitle("My Music").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { if catalog.uid.isEmpty || catalog.cookie.isEmpty { accountOpen = true } else if !catalog.connected { await catalog.connect(store) } }
        }.presentationDragIndicator(.visible)
    }
    private var account: some View {
        Section {
            DisclosureGroup(catalog.connected ? "NetEase account connected" : "Connect NetEase account", isExpanded: $accountOpen) {
                TextField("NetEase UID", text: $catalog.uid).keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("MUSIC_U", text: $catalog.cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Saved securely on this iPhone. Enter your account once to load playlists.").font(.caption).foregroundStyle(VesperTheme.muted)
                Button("Connect and load playlists") { Task { await catalog.connect(store); if catalog.connected { accountOpen = false } } }.disabled(catalog.busy)
            }
        }
    }
    private var shortcuts: some View {
        Section("Made for you") {
            shortcut("Daily mix", "sparkles", "recommendations")
            shortcut("Personal FM", "music.note", "personal-fm")
            shortcut("Recently played", "clock", "recent-plays")
            shortcut("Liked songs", "heart", "liked-songs")
            shortcut("Weekly favorites", "repeat", "play-history")
        }.disabled(catalog.busy || !catalog.connected)
    }
    private func shortcut(_ title: String, _ icon: String, _ action: String) -> some View {
        Button { Task { await catalog.load(action, store: store) } } label: { Label(title, systemImage: icon).frame(minHeight: 32) }
    }
    private var playlists: some View {
        Section {
            Button("Refresh playlists") { Task { await catalog.connect(store) } }.disabled(catalog.busy)
            if catalog.playlists.isEmpty { Text("Connect your account to see your playlists here.").font(.subheadline).foregroundStyle(VesperTheme.muted) }
            ForEach(catalog.playlists) { playlist in
                Button { Task { await catalog.load("playlist", store: store, payload: ["playlistId": .string(playlist.id)]) } } label: {
                    HStack(spacing: 12) {
                        Artwork(url: playlist["cover"].string).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 4) { Text(playlist["name"].string).font(.subheadline); Text("\(Int(playlist["trackCount"].number)) songs").font(.caption).foregroundStyle(VesperTheme.muted) }
                        Spacer(); Image(systemName: "chevron.right").font(.caption)
                    }.foregroundStyle(VesperTheme.ink)
                }.disabled(catalog.busy)
            }
        } header: { Text("My playlists") }
    }
    private var search: some View {
        Section {
            TextField("Search songs, artists or albums", text: $query).submitLabel(.search).onSubmit(searchSongs)
            Button("Search", action: searchSongs).disabled(catalog.busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private func searchSongs() { guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; Task { await catalog.load("search", store: store, payload: ["query": .string(query), "limit": .number(30)]) } }
    private var collection: some View {
        Section {
            Button { catalog.collection = .null } label: { Label("Back", systemImage: "chevron.left") }
            Text(catalog.collection["title"].string.isEmpty ? "Songs" : catalog.collection["title"].string).font(.headline)
            HStack {
                Button("Play all") { Task { await catalog.prepare(catalog.collection["tracks"].array, store: store, player: player) } }
                Spacer()
                Button("Sync queue") { Task { await catalog.prepare(catalog.collection["tracks"].array, store: store, player: player, autoplay: false) } }
            }.disabled(catalog.busy || catalog.collection["tracks"].array.isEmpty)
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
