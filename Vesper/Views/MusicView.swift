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
    var body: some View {
        Page(title: "Music", subtitle: "Stay for another song.") {
            GlassCard {
                VStack(spacing: 18) {
                    Artwork(url: player.track["cover"].string).frame(width: 210, height: 210).clipShape(Circle()).padding(.top, 10)
                    Text(player.track["title"].string.isEmpty ? "Your music" : player.track["title"].string).font(.title3)
                    Text(player.track["artist"].string).foregroundStyle(VesperTheme.muted)
                    Slider(value: Binding(get: { min(player.position, max(1, player.duration)) }, set: { player.seek($0) }), in: 0...max(1, player.duration)).disabled(player.duration <= 0)
                    HStack { Text(time(player.position)); Spacer(); Text(time(player.duration)) }.font(.caption).monospacedDigit()
                    PlaybackControls().font(.title2).padding(.bottom, 12)
                }.frame(maxWidth: .infinity)
            }
            Text("Library").font(VesperTheme.title(30))
            if player.tracks.isEmpty { EmptyCard(title: "No songs yet", message: "Your existing Vesper music library appears after connecting.") }
            ForEach(player.tracks) { track in
                Button { player.select(track) } label: {
                    GlassCard(padding: 12) { HStack { Artwork(url: track["cover"].string).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading) { Text(track["title"].string); Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted) }; Spacer(); if player.track.id == track.id { Image(systemName: "waveform") } } }
                }.buttonStyle(.plain)
            }
        }.task { player.updateLibrary(store.document("music").array) }
        .onChange(of: store.document("music")) { _, value in player.updateLibrary(value.array) }
        .alert("Music", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("OK") { player.error = nil } } message: { Text(player.error ?? "") }
    }
    private func time(_ seconds: Double) -> String { let s = Int(max(0, seconds)); return String(format: "%d:%02d", s / 60, s % 60) }
}
