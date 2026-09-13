import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    let navigate: (Destination) -> Void
    @EnvironmentObject private var chat: ChatSession
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.subheadline).foregroundStyle(VesperTheme.muted)
                        Text(greeting + ", Vera").font(VesperTheme.title(40)).minimumScaleFactor(0.65).lineLimit(1)
                        Text("A place for today, too.").foregroundStyle(VesperTheme.muted)
                    }.padding(.vertical, 14)
                    if !store.connected {
                        Button { navigate(.settings) } label: { EmptyCard(title: "Welcome home", message: "Connect your existing Vesper account in Settings.") }.buttonStyle(.plain)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        Button { navigate(.desire) } label: {
                            GlassCard { VStack(alignment: .leading) { cardTitle("Desire"); Spacer(); FlowerView().frame(maxWidth: .infinity); Spacer() }.frame(height: cardHeight) }
                        }.buttonStyle(.plain).frame(maxWidth: .infinity)
                        VStack(spacing: 14) {
                            GlassCard { VStack(alignment: .leading, spacing: 10) {
                                Text("Usage").font(VesperTheme.title(26))
                                Text("Weekly limit").font(.caption)
                                if let remaining = remainingUsage { Text("\(remaining)%").font(.caption); ProgressView(value: Double(remaining), total: 100).tint(VesperTheme.accent) }
                                else { Button("Refresh") { Task { chat.configure(store); await chat.loadUsage() } }.font(.caption).disabled(store.token.isEmpty) }
                            }}
                            GlassCard { VStack(alignment: .leading, spacing: 8) {
                                Button { navigate(.notes) } label: { cardTitle("Notes") }
                                ScrollView { Text(store.document("notes").array.first?["text"].string ?? "A little space for your thoughts.").font(.footnote).frame(maxWidth: .infinity, alignment: .leading) }
                            }.frame(height: max(85, cardHeight - 134)) }
                        }.frame(width: max(120, (min(geometry.size.width, 780) - 54) * 0.36))
                    }
                    HStack(alignment: .top, spacing: 14) {
                        GlassCard { VStack(alignment: .leading, spacing: 14) {
                            Button { navigate(.reminders) } label: { cardTitle("Reminders") }
                            let todos = store.document("todos").array.filter { !$0["done"].bool }
                            if todos.isEmpty { Text("Something you want to do today? Leave yourself a reminder.").font(.footnote).foregroundStyle(VesperTheme.muted) }
                            ForEach(Array(todos.prefix(3))) { item in
                                Button { Task { var changed = item; changed["done"] = .bool(true); _ = await store.upsert("todos", item: changed) } } label: { Label(item["title"].string, systemImage: "circle").font(.footnote).multilineTextAlignment(.leading) }
                            }
                            Spacer(minLength: 0)
                        }.frame(height: cardHeight) }.frame(width: max(132, (min(geometry.size.width, 780) - 54) * 0.38))
                        GlassCard { VStack(spacing: 10) {
                            Button { navigate(.music) } label: { cardTitle("Music") }
                            Artwork(url: player.track["cover"].string).frame(width: 85, height: 85).clipShape(Circle())
                            Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string).font(.footnote).lineLimit(1)
                            Text(player.track["artist"].string).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                            PlaybackControls().font(.title3)
                            Spacer(minLength: 0)
                        }.frame(height: cardHeight) }
                    }
                }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }.refreshable { await store.refresh() }
        }.task { player.updateLibrary(store.document("music").array) }
        .onChange(of: store.document("music")) { _, tracks in player.updateLibrary(tracks.array) }
    }
    private var cardHeight: CGFloat { 220 }
    private var remainingUsage: Int? {
        let limits = chat.usage["rateLimitsByLimitId"]["codex"] == .null ? chat.usage["rateLimits"] : chat.usage["rateLimitsByLimitId"]["codex"]
        let windows = [limits["primary"], limits["secondary"]]
        guard let weekly = windows.first(where: { $0["windowDurationMins"].number == 10080 }), case .number(let used) = weekly["usedPercent"] else { return nil }
        return Int(max(0, min(100, 100 - used)).rounded())
    }
    private var greeting: String { let h = Calendar.current.component(.hour, from: .now); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }
    private func cardTitle(_ value: String) -> some View { HStack { Text(value).font(VesperTheme.title(27)).minimumScaleFactor(0.7).lineLimit(1); Spacer(minLength: 2); Image(systemName: "chevron.right").font(.caption2) } }
}
struct FlowerView: View {
    var values: [Double] = [60, 60, 60, 60, 60, 60]
    var body: some View {
        ZStack {
            ForEach(0..<6) { i in
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.8), VesperTheme.accent.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 48 + CGFloat(values[i]) * 0.32).offset(y: -24).rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(Color(red: 1, green: 0.97, blue: 0.79)).frame(width: 15, height: 15)
        }.frame(height: 130).accessibilityLabel("Desire flower")
    }
}
