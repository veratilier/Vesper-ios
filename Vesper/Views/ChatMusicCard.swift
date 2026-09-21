import SwiftUI

struct ChatMusicCard: View {
    let track: JSONValue
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var store: AppStore
    private var selected: Bool { player.track.id == track.id && player.playing }
    var body: some View {
        Button {
            player.configure(store)
            if selected { player.pause() } else { player.select(track) }
        } label: {
            HStack(spacing: 12) {
                Artwork(url: track["cover"].string.isEmpty ? track["artwork"].string : track["cover"].string).frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(track["title"].string).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                    Text("Listen together").font(.caption2).foregroundStyle(VesperTheme.muted)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "pause.fill" : "play.fill")
            }.frame(width: 255, alignment: .leading).padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel("Play " + track["title"].string)
    }
}
