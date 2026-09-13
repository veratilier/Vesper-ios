import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var desire: JSONValue = .null
    @State private var desireError = false
    @State private var refreshingUsage = false
    let navigate: (Destination) -> Void
    private let fields = ["longing", "tenderness", "playfulness", "intensity", "attachment", "possessiveness"]
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 13)).foregroundStyle(VesperTheme.muted)
                        Text(greeting + ", Vera").font(VesperTheme.title(32)).minimumScaleFactor(0.65).lineLimit(1)
                        Text("A place for today, too.").font(.system(size: 14)).foregroundStyle(VesperTheme.muted)
                    }.padding(.top, 10).padding(.bottom, 4)
                    if !store.connected {
                        Button("Connect Vesper in Settings") { navigate(.settings) }.font(.footnote)
                    }
                    let width = max(240, min(geometry.size.width, 650) - 32)
                    let height: CGFloat = typeSize.isAccessibilitySize ? 300 : max(208, (geometry.size.height - 152) / 2)
                    if typeSize.isAccessibilitySize {
                        desireCard(height: height)
                        usageCard
                        notesCard(height: 150)
                        remindersCard(height: height)
                        musicCard(height: height)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            desireCard(height: height).frame(width: (width - 12) * 0.60)
                            VStack(spacing: 12) { usageCard.frame(height: 80); notesCard(height: height - 92) }
                        }
                        HStack(alignment: .top, spacing: 12) {
                            remindersCard(height: height).frame(width: (width - 12) * 0.37)
                            musicCard(height: height)
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 20).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }.refreshable { await store.refresh(); await loadDesire(); await loadUsage() }
        }.buttonStyle(.plain)
        .task { player.updateLibrary(store.document("music").array); await loadDesire() }
        .onChange(of: store.document("music")) { _, tracks in player.updateLibrary(tracks.array) }
        .onChange(of: store.token) { _, _ in Task { await loadDesire() } }
        .onChange(of: phase) { _, value in if value == .active { Task { await loadDesire() } } }
    }
    private func desireCard(height: CGFloat) -> some View {
        Button { navigate(.desire) } label: {
            HomeCard {
                VStack(alignment: .leading, spacing: 0) {
                    cardTitle("Desire")
                    Spacer(minLength: 0)
                    HomeDesireFlower(values: fields.map { key in
                        if case .number(let value) = desire[key] { return min(100, max(0, value)) }; return nil
                    }).frame(height: 132).frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                    if desire == .null { Text(desireError ? "Unable to refresh" : "Not loaded yet").font(.system(size: 10)).foregroundStyle(VesperTheme.muted) }
                }
            }.frame(height: height)
        }
    }
    private var usageCard: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Usage").font(VesperTheme.title(21)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { Task { await loadUsage() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 28) }.accessibilityLabel("Refresh usage").disabled(refreshingUsage || store.token.isEmpty)
                }
                HStack { Text("Weekly limit"); Spacer(minLength: 2); Text(remainingUsage.map { "\($0)%" } ?? "—") }.font(.system(size: 10))
                if let remaining = remainingUsage { ProgressView(value: Double(remaining), total: 100).tint(VesperTheme.accent) }
                else { Text(chat.loadingUsage ? "Loading…" : (chat.usageError == nil ? "Tap refresh" : "Unable to refresh · Retry")).font(.system(size: 9)).foregroundStyle(VesperTheme.muted) }
            }
        }
    }
    private func notesCard(height: CGFloat) -> some View {
        Button { navigate(.notes) } label: {
            HomeCard {
                VStack(alignment: .leading, spacing: 7) {
                    cardTitle("Notes")
                    Text(store.document("notes").array.first?["text"].string ?? "A little space for your thoughts.")
                        .font(.system(size: 12)).lineSpacing(2).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
            }.frame(height: height)
        }
    }
    private func remindersCard(height: CGFloat) -> some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Button { navigate(.reminders) } label: { cardTitle("Reminders") }
                let todos = store.document("todos").array.filter { !$0["done"].bool }
                if todos.isEmpty { Text("Something you want to do today? Leave yourself a reminder.").font(.system(size: 12)).lineSpacing(3).foregroundStyle(VesperTheme.muted) }
                ForEach(Array(todos.prefix(2))) { item in
                    Button { Task { var changed = item; changed["done"] = .bool(true); _ = await store.upsert("todos", item: changed) } } label: { Label(item["title"].string, systemImage: "circle").font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading).frame(minHeight: 44) }.disabled(store.saving)
                }
                Spacer(minLength: 0)
            }
        }.frame(height: height)
    }
    private func musicCard(height: CGFloat) -> some View {
        HomeCard {
            VStack(spacing: 5) {
                Button { navigate(.music) } label: { cardTitle("Music") }
                Artwork(url: player.track["cover"].string).frame(width: 76, height: 76).clipShape(Circle())
                Text(player.track["title"].string.isEmpty ? "Choose a song" : player.track["title"].string).font(.system(size: 11)).lineLimit(1)
                Text(player.track["artist"].string).font(.system(size: 10)).foregroundStyle(VesperTheme.muted).lineLimit(1)
                PlaybackControls().font(.system(size: 18)).frame(height: 36)
                Spacer(minLength: 0)
            }
        }.frame(height: height)
    }
    private func loadDesire() async {
        guard !store.token.isEmpty else { desire = .null; return }
        do { let response = try await store.api.request("/api/desire"); desire = response["data"]; desireError = false }
        catch { desireError = true }
    }
    private func loadUsage() async {
        guard !refreshingUsage, !store.token.isEmpty else { return }
        refreshingUsage = true; defer { refreshingUsage = false }
        chat.configure(store); await chat.loadUsage()
    }
    private var remainingUsage: Int? {
        chat.weeklyRemaining
    }
    private var greeting: String { let h = Calendar.current.component(.hour, from: .now); return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening" }
    private func cardTitle(_ value: String) -> some View {
        HStack { Text(value).font(VesperTheme.title(23)).minimumScaleFactor(0.6).lineLimit(1); Spacer(minLength: 1); Image(systemName: "chevron.right").font(.system(size: 10)) }
    }
}
private struct HomeCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.91, green: 0.94, blue: 0.97).opacity(0.80), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.90), lineWidth: 1.3))
    }
}
private struct HomeDesireFlower: View {
    let values: [Double?]
    private let angles: [Double] = [-30, 30, -90, 90, -150, 150]
    var body: some View {
        ZStack {
            ForEach(0..<6) { index in
                let value = values[index]
                let scale = 0.45 + (value ?? 0) * 0.0055
                Image("DesirePetal").resizable().frame(width: 58, height: 70)
                    .offset(y: -28).scaleEffect(scale).rotationEffect(.degrees(angles[index]))
                    .opacity(value == nil ? 0.3 : 0.65 + (value ?? 0) * 0.0035)
            }
            Circle().fill(Color(red: 1, green: 0.97, blue: 0.79)).frame(width: 8, height: 8)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Desire flower, sized by current mood values")
    }
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
