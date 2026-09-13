import SwiftUI

@main struct VesperApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var player = MusicPlayer()
    @StateObject private var chat = ChatSession()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(player).environmentObject(chat)
                .tint(VesperTheme.ink).foregroundStyle(VesperTheme.ink).preferredColorScheme(.light)
        }
    }
}
enum Destination: String, CaseIterable, Identifiable {
    case home = "Home", chat = "Chat", desire = "Desire", journal = "Journal", notes = "Notes"
    case reminders = "Reminders", dates = "Dates", music = "Music", album = "Album", memory = "Memory", pandora = "Pandora", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .chat: return "bubble.left"
        case .desire: return "heart"
        case .journal: return "book.closed"
        case .notes: return "note.text"
        case .reminders: return "checklist"
        case .dates: return "calendar"
        case .music: return "music.note"
        case .album: return "photo.on.rectangle"
        case .memory: return "brain.head.profile"
        case .pandora: return "shippingbox"
        case .settings: return "slider.horizontal.3"
        }
    }
}
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @State private var opening = true
    @Environment(\.scenePhase) private var phase
    @State private var destination: Destination = .home
    @State private var sidebar = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack(alignment: .leading) {
        NavigationStack {
            ZStack {
                Background()
                if destination == .home {
                    VStack(spacing: 0) { homeHeader; content }
                } else { content }
            }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(destination == .home || destination == .chat ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); withAnimation { sidebar = true } } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") }
                    ToolbarItem(placement: .principal) { Text(destination == .home ? "Vesper" : destination.rawValue).font(destination == .home ? VesperTheme.title(28) : .headline) }
                    ToolbarItem(placement: .topBarTrailing) {
                        if destination != .music { Button { destination = .settings } label: { Image(systemName: "person.crop.circle").font(.title2) }.accessibilityLabel("Settings") }
                    }
                }
                .alert("Vesper", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                    Button("OK") { store.error = nil }
                } message: { Text(store.error ?? "") }
                .opacity(appeared ? 1 : 0)
                .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { appeared = true } }
                .task { await store.refresh() }
                .onChange(of: phase) { _, value in if value == .active { Task { await store.refresh() } } }
        }
        .accessibilityHidden(sidebar || opening)
        if sidebar {
            Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { withAnimation { sidebar = false } }.accessibilityLabel("Close sidebar").accessibilityAddTraits(.isButton)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vesper").font(VesperTheme.title(32))
                    Spacer()
                    Button { withAnimation { sidebar = false } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close sidebar")
                }.padding(.horizontal, 20)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Destination.allCases) { item in
                            Button { withAnimation { destination = item; sidebar = false } } label: {
                                Label(item.rawValue, systemImage: item.icon).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(minHeight: 44)
                                    .background(destination == item ? Color.gray.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 14))
                            }.accessibilityAddTraits(destination == item ? .isSelected : [])
                        }
                        WeeklyUsageView().padding(.horizontal, 18).padding(.vertical, 12)
                    }.padding(.horizontal, 12)
                }
            }.padding(.top, 8).frame(width: 280).frame(maxHeight: .infinity)
                .background(.regularMaterial).transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { withAnimation { sidebar = false } } })
                .accessibilityAddTraits(.isModal)
        }
        if opening { OpeningView { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { opening = false } }.transition(.opacity).zIndex(2) }
        }.task(id: store.token) { await refreshUsage() }
        .onChange(of: sidebar) { _, open in if open { Task { await refreshUsage() } } }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await refreshUsage() } } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: sidebar)
    }
    @ViewBuilder private var content: some View {
        switch destination {
        case .home: HomeView(navigate: { destination = $0 })
        case .chat: ChatView(onMenu: { withAnimation { sidebar = true } })
        case .desire: DesireView()
        case .journal: JournalView()
        case .notes: CollectionView(kind: .notes)
        case .reminders: CollectionView(kind: .reminders)
        case .dates: CollectionView(kind: .dates)
        case .music: MusicView()
        case .album: AlbumView()
        case .memory: MemoryView()
        case .pandora: PandoraView()
        case .settings: SettingsView()
        }
    }
    private var homeHeader: some View {
        HStack {
            Button { withAnimation { sidebar = true } } label: { Image(systemName: "line.3.horizontal").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Open sidebar")
            Spacer()
            Text("Vesper").font(VesperTheme.title(27))
            Spacer()
            Button { destination = .settings } label: { Image(systemName: "person.crop.circle").font(.system(size: 25)).frame(width: 44, height: 44) }.accessibilityLabel("Settings")
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4)
    }
    private func refreshUsage() async {
        guard !store.token.isEmpty else { return }
        chat.configure(store); await chat.loadUsage()
    }
}

struct OpeningView: View {
    let enter: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var ready = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.92, green: 0.94, blue: 0.96)
                Image("OpeningScene").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped().opacity(visible ? 1 : 0)
                VStack(spacing: 12) {
                    Text("Vesper").font(VesperTheme.title(72))
                    Text("Somewhere we belong.").font(.system(size: 15, design: .serif).italic())
                }.foregroundStyle(.white).shadow(color: .black.opacity(0.25), radius: 8)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.30).opacity(ready ? 1 : 0)
                VStack { Spacer(); Button(action: enter) {
                    Text("Enter Vesper  ›").font(.system(size: 20, design: .serif).italic())
                        .padding(.horizontal, 30).padding(.vertical, 13)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.7)))
                }.buttonStyle(.plain).padding(.bottom, max(40, geometry.size.height * 0.09)).opacity(ready ? 1 : 0).disabled(!ready) }
            }
        }.ignoresSafeArea().task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.85)) { visible = true }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(850)) }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { ready = true }
        }
    }
}

struct WeeklyUsageView: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weekly usage").font(.system(size: 12))
                Spacer()
                Button { Task { chat.configure(store); await chat.loadUsage() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
                }.disabled(chat.loadingUsage || store.token.isEmpty).accessibilityLabel("Refresh weekly usage")
            }
            if let remaining = chat.weeklyRemaining {
                ProgressView(value: Double(100 - remaining), total: 100)
                Text("\(100 - remaining)% used · \(remaining)% remaining").font(.system(size: 11))
            } else { Text(chat.loadingUsage ? "Loading…" : (chat.usageError ?? "Connect in Settings")).font(.system(size: 11)) }
        }.foregroundStyle(VesperTheme.muted)
    }
}
