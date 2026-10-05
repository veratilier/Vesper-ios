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
    case home = "Home", chat = "Chat", desire = "Desire", journal = "Journal", letters = "Letters", notes = "Notes"
    case workflow = "Workflow", jottings = "Sketch", alarms = "Alarms", reminders = "Reminders", dates = "Dates", music = "Music", album = "Album", memory = "Memory", readingRoom = "Library", bookmarks = "Bookmarks", movieRoom = "Cinema", weather = "Weather", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .chat: return "bubble.left"
        case .desire: return "heart"
        case .journal: return "book.closed"
        case .letters: return "envelope"
        case .notes: return "note.text"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .jottings: return "pencil.line"
        case .alarms: return "alarm"
        case .reminders: return "checklist"
        case .dates: return "calendar"
        case .music: return "music.note"
        case .album: return "photo.on.rectangle"
        case .memory: return "brain.head.profile"
        case .readingRoom: return "book.pages"
        case .bookmarks: return "bookmark"
        case .movieRoom: return "film"
        case .weather: return "cloud.sun"
        case .settings: return "slider.horizontal.3"
        }
    }
}
/// Discard obsolete/duplicate destinations and append newly added features.
enum VesperGridOrder {
    static let defaults: [Destination] = [.desire, .journal, .notes, .dates, .reminders, .music, .album, .memory, .readingRoom, .bookmarks, .movieRoom, .alarms, .jottings, .workflow, .weather]
    static func restore(_ saved: String) -> [Destination] {
        let names = (try? JSONDecoder().decode([String].self, from: Data(saved.utf8))) ?? []
        var seen = Set<String>()
        return (names.compactMap { name -> Destination? in name == "随写" ? .jottings : Destination(rawValue: name) } + defaults).filter {
            defaults.contains($0) && seen.insert($0.id).inserted
        }
    }
    static func encode(_ pages: [Destination]) -> String {
        String(decoding: (try? JSONEncoder().encode(pages.map(\.rawValue))) ?? Data(), as: UTF8.self)
    }
    static func move(_ page: Destination, to target: Destination, in pages: [Destination]) -> [Destination] {
        guard page != target, let from = pages.firstIndex(of: page), let to = pages.firstIndex(of: target) else { return pages }
        var result = pages
        result.insert(result.remove(at: from), at: to)
        return result
    }
}

private struct VesperGridFrames: PreferenceKey {
    static var defaultValue: [Destination: CGRect] = [:]
    static func reduce(value: inout [Destination: CGRect], nextValue: () -> [Destination: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct VesperAppGrid: View {
    @Binding var editing: Bool
    let open: (Destination) -> Void
    @AppStorage("vesperAppGridOrder") private var savedOrder = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pages = VesperGridOrder.defaults
    @State private var frames: [Destination: CGRect] = [:]
    @State private var dragged: Destination?
    @State private var dragOrigin = CGRect.zero
    @State private var translation = CGSize.zero
    @GestureState private var pressing = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 22) {
            ForEach(pages) { page in
                Button { if !editing { open(page) } } label: { tile(page) }
                    .buttonStyle(.plain)
                    .opacity(dragged == page ? 0.2 : 1)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: VesperGridFrames.self,
                                value: [page: geometry.frame(in: .named("vesperAppGrid"))])
                        }
                    }
                    .accessibilityIdentifier("vesper-app-" + page.rawValue)
                    .accessibilityHint(editing ? "Drag to rearrange" : "Long press to rearrange")
                    .accessibilityAction(named: "Move earlier") { moveAccessibly(page, by: -1) }
                    .accessibilityAction(named: "Move later") { moveAccessibly(page, by: 1) }
            }
        }
        .coordinateSpace(name: "vesperAppGrid")
        .onPreferenceChange(VesperGridFrames.self) { frames = $0 }
        .overlay(alignment: .topLeading) {
            if let dragged {
                tile(dragged).frame(width: dragOrigin.width, height: dragOrigin.height)
                    .scaleEffect(1.1).shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                    .position(x: dragOrigin.midX + translation.width, y: dragOrigin.midY + translation.height)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        // Observe long presses without taking ordinary taps away from the tile buttons.
        // Once a long press succeeds, editing suppresses button activation on release.
        .simultaneousGesture(LongPressGesture(minimumDuration: editing ? 0.12 : 0.45, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("vesperAppGrid")))
            .updating($pressing) { _, active, _ in active = true }
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    if !editing { editing = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    guard let drag else { return }
                    if dragged == nil, let page = pages.first(where: { frames[$0]?.contains(drag.startLocation) == true }), let frame = frames[page] {
                        dragged = page; dragOrigin = frame
                    }
                    translation = drag.translation
                    if let dragged, let target = pages.first(where: { frames[$0]?.contains(drag.location) == true }), target != dragged {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            pages = VesperGridOrder.move(dragged, to: target, in: pages)
                        }
                    }
                default: break
                }
            }
            .onEnded { _ in finishDrag() })
        .onChange(of: pressing) { _, active in if !active { finishDrag() } }
        .onChange(of: editing) { _, value in if !value { finishDrag() } }
        .onAppear { pages = VesperGridOrder.restore(savedOrder) }
        .onDisappear { finishDrag(); editing = false }
    }

    private func tile(_ page: Destination) -> some View {
        let icon = Image(systemName: page.icon).font(.system(size: 25, weight: .medium))
            .frame(width: 56, height: 56)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true)
        return VStack(spacing: 8) {
            if editing && !reduceMotion {
                icon.phaseAnimator([false, true]) { image, phase in
                    image.rotationEffect(.degrees(phase ? 1.5 : -1.5))
                } animation: { _ in .easeInOut(duration: 0.16) }
            } else { icon }
            Text(page.rawValue).font(.caption).lineLimit(2).minimumScaleFactor(0.85)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .top).contentShape(Rectangle())
    }

    private func finishDrag() {
        if dragged != nil { savedOrder = VesperGridOrder.encode(pages) }
        dragged = nil; translation = .zero
    }
    private func moveAccessibly(_ page: Destination, by offset: Int) {
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return }
        pages = VesperGridOrder.move(page, to: pages[index + offset], in: pages)
        savedOrder = VesperGridOrder.encode(pages)
    }
}

private struct FloatingCallSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let measured = nextValue()
        if measured != .zero { value = measured }
    }
}
struct RootView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    @ObservedObject private var letterInbox = LetterInbox.shared
    @ObservedObject private var chatInbox = ChatInbox.shared
    @State private var nativeTab = 0
    @State private var libraryPath: [Destination] = []
    @State private var libraryEditing = false
    @State private var vesperPage: Destination = .desire
    @StateObject private var callPresentation = NativeCallPresentation.shared
    @State private var floatingCallCenter: CGPoint?
    @State private var floatingCallSize = CGSize(width: 220, height: 64)
    @GestureState private var floatingCallDrag = CGSize.zero
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
                    NativeChatHome().tabItem { Label("Chat", systemImage: "bubble.left") }.badge(chatInbox.hasUpdates ? " " : nil as String?).tag(1)
                    appLibrary.tabItem { Label("Collection", systemImage: "square.grid.2x2.fill") }.tag(2)
                    shell(.letters).tabItem { Label("Letters", systemImage: "envelope") }.badge(letterInbox.hasUpdates ? " " : nil as String?).tag(3)
                    shell(.settings).tabItem { Label("Setting", systemImage: "gearshape") }.tag(4)
                }.onChange(of: nativeTab) { _, tab in
                    switch tab {
                    case 0: destination = .home
                    case 1: destination = .chat
                    case 2: destination = nativeVesperDestination
                    case 3: destination = .letters
                    default: destination = .settings
                    }
                }
    }
    private var appLibrary: some View {
        NavigationStack(path: $libraryPath) {
            ZStack {
                Background()
                ScrollView {
                    VesperAppGrid(editing: $libraryEditing) { page in libraryPath.append(page) }
                        .padding(18)
                }
            }.transparentNavigationTop().navigationTitle("Collection")
                .navigationDestination(for: Destination.self) { page in content(page).transparentNavigationTop().background { Background() }.navigationTitle(page.rawValue).navigationBarTitleDisplayMode(.inline) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        if libraryEditing { Button("Done") { libraryEditing = false }.fontWeight(.semibold) }
                        else { AppearancePicker() }
                    }
                }
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
        if !opening {
            navigationSurface.accessibilityHidden(sidebar)
        }
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
                CallInvitation(accept: { chat.incomingCall = false; navigate(.chat); callPresentation.open(initiator: "agent") }, decline: { chat.incomingCall = false })
                    .padding(28).transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .overlay {
            if callPresentation.presented {
                GeometryReader { geometry in
                    NativeCallView(initiator: callPresentation.initiator)
                        .fixedSize(horizontal: callPresentation.minimized, vertical: callPresentation.minimized)
                        .background {
                            if callPresentation.minimized {
                                GeometryReader { bubble in
                                    Color.clear.preference(key: FloatingCallSizeKey.self, value: bubble.size)
                                }
                            }
                        }
                        .frame(width: callPresentation.minimized ? nil : geometry.size.width,
                               height: callPresentation.minimized ? nil : geometry.size.height)
                        .position(callPresentation.minimized ? floatingPosition(in: geometry.size)
                                  : CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2))
                        .onPreferenceChange(FloatingCallSizeKey.self) { measured in
                            if measured.width > 0 && measured.height > 0 { floatingCallSize = measured }
                        }
                        // A recognized drag must not also activate the compact call's open button.
                        .highPriorityGesture(DragGesture(minimumDistance: 10)
                            .updating($floatingCallDrag) { drag, offset, _ in
                                if callPresentation.minimized { offset = drag.translation }
                            }
                            .onEnded { drag in
                                guard callPresentation.minimized else { return }
                                let center = clampedFloatingPosition(
                                    floatingCallCenter ?? defaultFloatingPosition(in: geometry.size),
                                    in: geometry.size)
                                floatingCallCenter = clampedFloatingPosition(
                                    CGPoint(x: center.x + drag.translation.width, y: center.y + drag.translation.height),
                                    in: geometry.size)
                            }, including: callPresentation.minimized ? .all : .none)
                        .accessibilityHint(callPresentation.minimized ? "Drag to move the call window" : "")
                }.zIndex(3)
            }
        }
    }
    private func defaultFloatingPosition(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - floatingCallSize.width / 2 - 12,
                y: floatingCallSize.height / 2 + 12)
    }
    private func floatingPosition(in size: CGSize) -> CGPoint {
        let center = floatingCallCenter ?? defaultFloatingPosition(in: size)
        return clampedFloatingPosition(
            CGPoint(x: center.x + floatingCallDrag.width, y: center.y + floatingCallDrag.height), in: size)
    }
    private func clampedFloatingPosition(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let halfWidth = min(floatingCallSize.width / 2, (size.width - 24) / 2)
        let halfHeight = min(floatingCallSize.height / 2, (size.height - 24) / 2)
        return CGPoint(x: min(max(point.x, halfWidth + 12), size.width - halfWidth - 12),
                       y: min(max(point.y, halfHeight + 12), size.height - halfHeight - 12))
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
        .task { if !callPresentation.presented { await CallLiveActivity.shared.endStale() } }
        .task(id: store.baseURL + "\n" + store.token) {
            while !Task.isCancelled {
                if phase == .active { await LetterNotifications.sync(store.api) }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: store.historyURL + "\n" + store.token) {
            while !Task.isCancelled {
                if phase == .active { await chatInbox.sync(store.api) }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: store.historyURL) { _, _ in chatInbox.clear() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in letterInbox.tick() }
        .onReceive(LetterNotificationRoute.shared.$letterID) { id in
            if id != nil { navigate(.letters) }
        }
        .task(id: store.token) { await refreshUsage() }
        .onChange(of: store.token) { _, _ in WidgetSync.clear(); letterInbox.clear(); chatInbox.clear() }
        .onChange(of: store.baseURL) { _, _ in letterInbox.clear() }
        .onOpenURL { url in
            guard url.scheme == "vesper" else { return }
            switch url.host {
            case "desire": navigate(.desire)
            case "notes": navigate(.notes)
            case "usage": sidebar = true; Task { await refreshUsage() }
            case "call": navigate(.chat); if callPresentation.presented { callPresentation.minimized = false }
            default: break
            }
        }
        .task(id: phase == .active && !opening) {
            guard phase == .active, !opening else { return }
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
        .onChange(of: phase) { _, phase in
            if phase != .inactive { chat.sceneChanged(active: phase == .active) }
            if phase == .active { Task { await refreshUsage(); await LetterNotifications.sync(store.api) } }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: sidebar)
    }
    private var nativeVesperDestination: Destination { vesperPage }
    private func navigate(_ page: Destination) {
        destination = page
        if ![.home, .chat, .letters, .settings].contains(page) { libraryPath = [page] }
        if [.desire, .journal, .notes, .dates, .music, .album].contains(page) { vesperPage = page }
        switch page {
        case .home: nativeTab = 0
        case .chat: nativeTab = 1
        case .letters: nativeTab = 3
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
                if page != .letters {
                    ToolbarItem(placement: .principal) {
                        if page == .home { homeWordmark }
                        else { Text(page.rawValue).font(.headline) }
                    }
                }
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
        case .letters: LettersView()
        case .notes: NotesBoard()
        case .workflow: WakeWorkflowView()
        case .jottings: JottingsView()
        case .alarms: AlarmsView()
        case .reminders: CollectionView(kind: .reminders)
        case .dates: CollectionView(kind: .dates)
        case .music: MusicView()
        case .album: AlbumView()
        case .memory: MemoryView()
        case .readingRoom: ReadingRoomView()
        case .bookmarks: BookmarksView()
        case .movieRoom: MovieRoomView()
        case .weather: WeatherView()
        case .settings: SettingsView()
        }
    }
    private var homeWordmark: some View {
        Text("Vesper").font(VesperTheme.title(26)).foregroundStyle(VesperTheme.ink.opacity(0.72))
    }
    private var homeHeader: some View {
        HStack {
            Button { withAnimation { sidebar = true } } label: { Image(systemName: "line.3.horizontal").font(.system(size: 20)).frame(width: 44, height: 44) }.accessibilityLabel("Open sidebar")
            Spacer()
            HStack(spacing: 8) { Image(VesperTheme.palette.emblem).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 8)); homeWordmark }
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
    @Environment(\.scenePhase) private var phase
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
                    if store.connected {
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
        .task(id: phase) {
            guard phase == .active else { return }
            await store.refresh(retryTransientFailures: true)
        }
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
        Task { @MainActor in
            if let id = info["letterId"] as? String {
                let api = AppStore().api
                guard info["letterScope"] as? String == LetterNotifications.scope(api) else { return }
                LetterNotificationRoute.shared.letterID = id
            } else { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: info) }
        }
        completionHandler()
    }
}
