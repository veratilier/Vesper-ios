import SwiftUI
import UserNotifications

@main struct VesperApp: App {
    @UIApplicationDelegateAdaptor(VesperNotificationDelegate.self) private var notificationDelegate
    @StateObject private var store = AppStore()
    @StateObject private var player = MusicPlayer()
    @StateObject private var chat = ChatSession()
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).environmentObject(player).environmentObject(chat).environmentObject(chat.composer)
                .tint(VesperTheme.ink).foregroundStyle(VesperTheme.ink).preferredColorScheme(palette == "black" ? .dark : .light)
                .onChange(of: palette) { _, value in ThemeIcons.apply(value) }
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
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    @State private var nativeTab = 0
    @State private var libraryPath: [Destination] = []
    @State private var vesperPage: Destination = .desire
    @State private var acceptedCall = false
    @State private var opening = true
    @Environment(\.scenePhase) private var phase
    @State private var destination: Destination = .home
    @State private var sidebar = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder private var navigationSurface: some View {
        if navigationStyle == "native" { nativeTabs }
        else if destination == .chat { NativeChatHome(onMenu: { sidebar = true }) }
        else { shell(destination) }
    }
    private var nativeTabs: some View {
                TabView(selection: $nativeTab) {
                    shell(.home).tabItem { Label("Home", systemImage: "house") }.tag(0)
                    NativeChatHome().tabItem { Label("Chat", systemImage: "bubble.left") }.tag(1)
                    appLibrary.tabItem { Label("Vesper", systemImage: "square.grid.2x2").environment(\.symbolVariants, .none) }.tag(2)
                    shell(.journal).tabItem { Label("Journal", systemImage: "book.closed") }.tag(3)
                    shell(.settings).tabItem { Label("Setting", systemImage: "gearshape") }.tag(4)
                }.onChange(of: nativeTab) { _, tab in
                    switch tab {
                    case 0: destination = .home
                    case 1: destination = .chat
                    case 2: destination = nativeVesperDestination
                    case 3: destination = .journal
                    default: destination = .settings
                    }
                }
    }
    private var appLibrary: some View {
        NavigationStack(path: $libraryPath) {
            ZStack {
                Background()
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 22) {
                        ForEach([Destination.desire, .notes, .dates, .reminders, .music, .album, .memory, .pandora]) { page in
                            NavigationLink(value: page) {
                                VStack(spacing: 8) {
                                    Image(systemName: page.icon).font(.system(size: 25, weight: .medium))
                                        .frame(width: 56, height: 56)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                                    Text(page.rawValue).font(.caption).multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .top)

                            }.buttonStyle(.plain)
                        }
                    }.padding(18)
                }
            }.transparentNavigationTop().navigationTitle("Vesper")
                .navigationDestination(for: Destination.self) { page in content(page).transparentNavigationTop().background { Background() }.navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline) }
                .toolbar { ToolbarItem(placement: .topBarTrailing) { AppearancePicker() } }
        }
    }
    private var sidebarPanel: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vesper").font(VesperTheme.title(32))
                    Spacer()
                    Button { withAnimation { sidebar = false } } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Close sidebar")
                }.padding(.horizontal, 20)
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(Destination.allCases) { item in
                            Button { withAnimation { navigate(item); sidebar = false } } label: {
                                Label(item.rawValue, systemImage: item.icon).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).frame(minHeight: 44)
                                    .background(destination == item ? Color.gray.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 14))
                            }.accessibilityAddTraits(destination == item ? .isSelected : [])
                        }
                    }.padding(.horizontal, 12)
                }
                Divider()
                WeeklyUsageView().padding(.horizontal, 28).padding(.bottom, 12)
            }.padding(.top, 8).frame(width: 280).frame(maxHeight: .infinity)
                .background(.regularMaterial).transition(.move(edge: .leading))
                .gesture(DragGesture().onEnded { if $0.translation.width < -60 { withAnimation { sidebar = false } } })
                .accessibilityAddTraits(.isModal)
    }
    private var scene: some View {
        ZStack(alignment: .leading) {
        navigationSurface
        .accessibilityHidden(sidebar || opening)
        if sidebar {
            Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { withAnimation { sidebar = false } }.accessibilityLabel("Close sidebar").accessibilityAddTraits(.isButton)
            sidebarPanel
        }
        if opening { OpeningView { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { opening = false } }.transition(.opacity).zIndex(2) }
        }
        .onChange(of: navigationStyle) { _, _ in navigate(destination); sidebar = false }
        .onAppear { navigate(destination) }
        .overlay {
            if chat.incomingCall {
                Color.black.opacity(0.18).ignoresSafeArea()
                CallInvitation(accept: { chat.incomingCall = false; navigate(.chat); acceptedCall = true }, decline: { chat.incomingCall = false })
                    .padding(28).transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .fullScreenCover(isPresented: $acceptedCall) { NativeCallView(initiator: "agent") }
    }
    private var lifecycle: some View {
        scene
        .onReceive(NotificationCenter.default.publisher(for: .init("VesperOpenConversation"))) { event in
            guard let id = event.userInfo?["conversationId"] as? String, !chat.busy, !chat.callActive else { return }
            navigate(.chat)
            Task {
                chat.configure(store)
                guard await chat.open(.object(["id": .string(id)])) else { return }
                if let messageID = event.userInfo?["messageId"] as? String { await chat.reveal(messageID) }
                NotificationCenter.default.post(name: .init("VesperConversationOpened"), object: nil)
            }
        }
         .task(id: store.token) { await refreshUsage() }
        .onChange(of: store.token) { _, _ in WidgetSync.clear() }
        .onOpenURL { url in
            guard url.scheme == "vesper" else { return }
            switch url.host {
            case "desire": navigate(.desire)
            case "notes": navigate(.notes)
            case "usage": sidebar = true; Task { await refreshUsage() }
            default: break
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            player.configure(store); player.synchronize()
            while !Task.isCancelled {
                if !store.token.isEmpty {
                    await store.refresh()
                    if let response = try? await store.api.request("/api/desire") { WidgetSync.desire(response["data"]) }
                    await refreshUsage()
                }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            player.configure(store)
            while !Task.isCancelled {
                await player.pollControl()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }
    var body: some View {
        lifecycle
        .task(id: sidebar) {
            guard sidebar else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                if phase == .active { await refreshUsage() }
            }
        }
        .onChange(of: chat.busy) { old, new in if old && !new && sidebar { Task { await refreshUsage() } } }
        .onChange(of: sidebar) { _, open in if open { Task { await refreshUsage() } } }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await refreshUsage() } } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: sidebar)
    }
    private var nativeVesperDestination: Destination { vesperPage }
    private func navigate(_ page: Destination) {
        destination = page
        if ![.home, .chat, .journal, .settings].contains(page) { libraryPath = [page] }
        if [.desire, .journal, .notes, .dates, .music, .album].contains(page) { vesperPage = page }
        switch page {
        case .home: nativeTab = 0
        case .chat: nativeTab = 1
        case .journal: nativeTab = 3
        case .settings: nativeTab = 4
        default: nativeTab = 2
        }
    }
    private func shell(_ page: Destination) -> some View {
        NavigationStack {
            ZStack {
                Background()
                if page == .home && navigationStyle != "native" { VStack(spacing: 0) { homeHeader; content(page) } }
                else { content(page) }
            }
            .transparentNavigationTop()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(page == .chat || (page == .home && navigationStyle != "native") ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if navigationStyle == "vesper" {
                        Button { withAnimation { sidebar = true } } label: { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar")
                    }
                }
                ToolbarItem(placement: .principal) { Text(page == .home ? "Vesper" : page.rawValue).font(.headline) }
                ToolbarItem(placement: .topBarTrailing) { AppearancePicker() }
            }
        }
        .alert("Vesper", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    @ViewBuilder private func content(_ page: Destination) -> some View {
        switch page {
        case .home: HomeView(navigate: { navigate($0) })
        case .chat: ChatView(onMenu: { withAnimation { sidebar = true } }, native: navigationStyle == "native")
        case .desire: DesireView()
        case .journal: JournalView()
        case .notes: NotesBoard()
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
            HStack(spacing: 8) { Image(VesperTheme.palette.emblem).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 8)); Text("Vesper").font(VesperTheme.title(27)) }
            Spacer()
            AppearancePicker().frame(width: 44, height: 44)
        }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 4)
    }
    private func refreshUsage() async {
        guard !store.token.isEmpty else { return }
        chat.configure(store); await chat.loadUsage()
    }
}

struct OpeningView: View {
    let enter: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var showingConnection = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var ready = false
    @State private var entering = false
    @AppStorage("vesperPalette") private var palette = "blue"
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.92, green: 0.94, blue: 0.96)
                Image(palette == "blue" ? "OpeningScene" : (VesperPalette(rawValue: palette) ?? .blue).background).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped().opacity(visible ? 1 : 0)
                VStack(spacing: 12) {
                    Text("Vesper").font(VesperTheme.title(72))
                    Text("Somewhere we belong.").font(.system(size: 15, design: .serif).italic())
                }.foregroundStyle(VesperTheme.ink).shadow(color: .black.opacity(0.08), radius: 8)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.30).opacity(ready ? 1 : 0)
                VStack(spacing: 14) { Spacer()
                    if store.connected && !store.loading {
                    Button { entering = true; enter() } label: {
                    Text("Enter Vesper  ›").font(.system(size: 20, design: .serif).italic())
                        .padding(.horizontal, 30).padding(.vertical, 13)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.7)))
                    }.buttonStyle(.plain).disabled(!ready || entering)
                    } else if store.loading {
                        ProgressView("Connecting to Vesper…")
                    } else {
                        Text(store.connectionError ?? "Connect your Vesper to continue.")
                            .font(.footnote).multilineTextAlignment(.center).padding(.horizontal, 28)
                        if !store.token.isEmpty {
                            Button("Retry connection") { Task { await store.connect() } }
                        }
                        Button("Connection settings") { showingConnection = true }
                    }
                }.padding(.bottom, max(40, geometry.size.height * 0.09)).opacity(ready ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: store.connected)
            }
        }.ignoresSafeArea()
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ConnectionView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingConnection = false } } }
            }
        }
        .task {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { visible = true }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(200)) }
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
                if let error = chat.usageError { Text("Refresh failed · " + error).font(.system(size: 10)) }
                else if let updated = chat.usageUpdatedAt { Text("Updated " + updated.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)) }
            } else { Text(chat.loadingUsage ? "Loading…" : (chat.usageError ?? "Connect in Settings")).font(.system(size: 11)) }
        }.foregroundStyle(VesperTheme.muted)
    }
}

final class VesperNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("message-") ? [] : [.banner, .sound, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: info) }
        completionHandler()
    }
}
