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
                    VStack(spacing: 0) { homeHeader; content; tabBar }
                } else { content }
            }
                .safeAreaInset(edge: .bottom, spacing: 0) { if destination != .chat && destination != .home { tabBar } }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(destination == .home ? .hidden : .visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); withAnimation { sidebar = true } } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") }
                    ToolbarItem(placement: .principal) { Text(destination == .home ? "Vesper" : destination.rawValue).font(destination == .home ? VesperTheme.title(28) : .headline) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { destination = .settings } label: { Image(systemName: "person.crop.circle").font(.title2) }.accessibilityLabel("Settings")
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
        .accessibilityHidden(sidebar)
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
                    }.padding(.horizontal, 12)
                }
            }.padding(.top, 8).frame(width: 280).frame(maxHeight: .infinity)
                .background(.regularMaterial).transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { withAnimation { sidebar = false } } })
                .accessibilityAddTraits(.isModal)
        }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: sidebar)
    }
    @ViewBuilder private var content: some View {
        switch destination {
        case .home: HomeView(navigate: { destination = $0 })
        case .chat: ChatView()
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
    private var tabBar: some View {
        HStack {
            ForEach([Destination.home, .chat, .music, .settings]) { item in
                Button { destination = item } label: {
                    VStack(spacing: 4) { Image(systemName: item.icon).font(.system(size: destination == .home ? 19 : 22)); Text(item.rawValue).font(destination == .home ? .system(size: 11) : .caption) }
                        .frame(maxWidth: .infinity).padding(.vertical, destination == .home ? 8 : 12)
                        .background(destination == item ? Color.gray.opacity(0.15) : .clear, in: Capsule())
                }.accessibilityAddTraits(destination == item ? .isSelected : [])
            }
        }.padding(5).background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 2)).padding(.horizontal, 20).padding(.bottom, 8)
    }
}
