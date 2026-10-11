import SwiftUI

struct ChatPromptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("vesperPalette") private var palette = "blue"
    @State private var draft = ChatPromptPreferences.load()
    @State private var original = ChatPromptPreferences.load()
    @State private var confirmingDiscard = false
    private var changed: Bool { draft != original }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("写下你希望 Rowan 如何与你聊天。")
                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
                TextEditor(text: $draft)
                    .font(.body).scrollContentBackground(.hidden)
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityLabel("Chat prompt text").accessibilityIdentifier("chat-prompt-editor")
                Text("保存在本机，VPS / MAC 聊天共用。从下一条消息开始使用，已有窗口也生效；不修改自唤醒 prompt。清空并保存即可停用。")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }.padding(20).background { Background() }
                .navigationTitle("Chat prompt").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { if changed { confirmingDiscard = true } else { dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            ChatPromptPreferences.save(draft)
                            original = draft
                            dismiss()
                        }.accessibilityIdentifier("chat-prompt-save")
                    }
                }
                .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                }
        }.foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            .preferredColorScheme(palette == "black" ? .dark : .light)
            .interactiveDismissDisabled(changed)
            .presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}

struct NativeChatHome: View {
    var sideBySide = VesperLayout.isMac
    var onMenu: (() -> Void)? = nil
    var onOpenMusic: (() -> Void)? = nil
    var onRootVisibilityChange: (Bool) -> Void = { _ in }
    @Environment(\.chatWorkspace) private var workspace
    var body: some View {
        if let workspace {
            ChatWorkspaceHome(workspace: workspace, sideBySide: sideBySide, onMenu: onMenu,
                              onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
        } else {
            NativeChatBackendHome(sideBySide: sideBySide, onMenu: onMenu,
                                  onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
        }
    }
}

private struct ChatWorkspaceHome: View {
    @ObservedObject var workspace: ChatBackendWorkspace
    var sideBySide: Bool
    var onMenu: (() -> Void)?
    var onOpenMusic: (() -> Void)?
    var onRootVisibilityChange: (Bool) -> Void
    var body: some View {
        let runtime = workspace.runtime(workspace.selectedBackend)
        NativeChatBackendHome(sideBySide: sideBySide, onMenu: onMenu,
                              onOpenMusic: onOpenMusic, onRootVisibilityChange: onRootVisibilityChange)
            .environmentObject(runtime.store).environmentObject(runtime.chat).environmentObject(runtime.chat.composer)
            .id(workspace.selectedBackend)
    }
}

private struct NativeChatBackendHome: View {
    var sideBySide = VesperLayout.isMac
    var onMenu: (() -> Void)? = nil
    var onOpenMusic: (() -> Void)? = nil
    var onRootVisibilityChange: (Bool) -> Void = { _ in }
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.chatWorkspace) private var workspace
    @Environment(\.scenePhase) private var phase
    @State private var welcomeLine = "A place for today, too."
    @State private var contactsVisible = false
    @State private var open = false
    @State private var loadingChat = false
    @State private var openingTask: Task<Void, Never>?
    @State private var searching = false
    @State private var showingFavorites = false
    @State private var showingChatPrompt = false
    @State private var openedOnce = false
    @State private var deletingConversation: JSONValue?
    @State private var deleting = false
    @State private var renamingConversation: JSONValue?
    @State private var conversationTitle = ""
    @State private var renaming = false
    @State private var editingContactName = false
    @State private var contactName = ""
    @State private var savingContactName = false
    @State private var activityRefreshID = 0
    @AppStorage("chat-contact.vps.window") private var vpsWindowID = ""
    @AppStorage("chat-contact.mac.window") private var macWindowID = ""
    private var selectedBackend: VesperBackend { store.activeBackend }
    private var backendSelection: Binding<VesperBackend> {
        Binding(get: { selectedBackend }, set: { backend in
            do { try workspace?.select(backend) } catch { chat.error = error.localizedDescription }
        })
    }
    @StateObject private var backendContacts = ChatBackendContacts()
    private var selectedContacts: ChatBackendContactSnapshot { backendContacts.snapshot(selectedBackend) }
    private var windowSelection: Binding<String> {
        Binding(get: { selectedBackend == .vps ? vpsWindowID : macWindowID }, set: { id in
            if selectedBackend == .vps { vpsWindowID = id } else { macWindowID = id }
        })
    }
    private var selectedClient: APIClient {
        backendContacts.client(selectedBackend) ?? APIClient(baseURL: selectedContacts.baseURL, historyURL: BackendConnection.load(selectedBackend).historyURL, token: "")
    }
    private var mainConversationID: String {
        selectedContacts.mainID
    }
    private var rowDisabled: Bool { store.loading || loadingChat || chat.busy || chat.openingMainRoom || chat.callActive || deleting || renaming || savingContactName }
    var body: some View {
        if sideBySide {
            HStack(spacing: 0) {
                NavigationStack { contactsWithDialogs }.frame(width: 300)
                Divider()
                NavigationStack {
                    ZStack {
                        Background()
                        if loadingChat && !chat.showingCachedHistory {
                            ProgressView("Opening chat…")
                        } else if open {
                            ChatView(onMenu: { open = false }, restoreLatest: false, inbox: workspace?.runtime(store.activeBackend).inbox)
                                .frame(maxWidth: 920).toolbar(.hidden, for: .navigationBar)
                        } else {
                            ContentUnavailableView("Your conversations", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("Choose Rowan or a conversation to continue."))
                        }
                    }
                }.frame(maxWidth: .infinity)
            }
        } else {
            NavigationStack { contactsWithDialogs }
        }
    }

    private var contactList: some View {
        List {
                Button { performForSelectedBackend { searching = true } } label: {
                    Label("Search messages", systemImage: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(VesperTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contactGlassSurface(verticalPadding: 12)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                ChatConversationDeck(windows: selectedContacts.windows, selected: windowSelection) { window in
                    Button { enterChat(window.isMain ? nil : window.conversation) } label: {
                        conversationRowContent(window.conversation, title: window.title,
                                               emptyPreview: selectedContacts.configured ? "Start chatting" : "Not configured", contacts: selectedContacts, showBackend: true)
                    }.buttonStyle(.plain)
                        .contactGlassSurface()
                        .accessibilityLabel("\(window.title), \(selectedBackend.title), \(preview(window.conversation, empty: "Start chatting"))")
                        .contextMenu {
                            if window.isMain {
                                Button { performForSelectedBackend { beginEditingContactName() } } label: { Label("Edit contact name", systemImage: "person.crop.circle") }
                            }
                            if let item = window.conversation {
                                Button { performForSelectedBackend { conversationTitle = item["title"].string; renamingConversation = item } } label: { Label("Rename conversation", systemImage: "pencil") }
                                Button(role: .destructive) { performForSelectedBackend { deletingConversation = item } } label: { Label("Delete conversation", systemImage: "trash") }
                            }
                        }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Text(welcomeLine)
                    .font(.system(.title3, design: .serif)).italic()
                    .foregroundStyle(VesperTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("chat-contact-greeting")
                ChatActivityHeatmap(refreshID: activityRefreshID, client: selectedClient).id(selectedBackend)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }.scrollContentBackground(.hidden).transparentNavigationTop().background { Background() }
            .listStyle(.plain)
            .onAppear { contactsVisible = true; onRootVisibilityChange(true); updateWelcomeLine() }
            .onDisappear { contactsVisible = false; onRootVisibilityChange(false) }
            .onChange(of: phase) { _, value in
                if value == .active && contactsVisible && !open && !searching && !showingFavorites { updateWelcomeLine() }
            }
            .refreshable { await refreshContacts(); activityRefreshID += 1 }
    }

    private var contactsWithNavigation: some View {
        contactList
            .safeAreaInset(edge: .bottom, spacing: 4) {
                if !NativeMusicAccessory.isSupported, let onOpenMusic { MiniMusicPlayer(openMusic: onOpenMusic) }
            }
            .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(VesperBackend.allCases) { backend in
                            let contact = backendContacts.snapshot(backend)
                            Button { backendSelection.wrappedValue = backend } label: {
                                Label(contact.agentName + " · " + backend.title,
                                      systemImage: backend == selectedBackend ? "checkmark" : backend == .vps ? "server.rack" : "laptopcomputer")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Chat").font(.headline)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }.foregroundStyle(VesperTheme.ink).frame(minHeight: 44)
                    }.accessibilityLabel("Switch contact").accessibilityValue(agentName + " · " + selectedBackend.title)
                        .accessibilityIdentifier("chat-contact-picker")
                }
                ToolbarItem(placement: .topBarLeading) { if let onMenu { Button(action: onMenu) { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { performForSelectedBackend { showingFavorites = true } } label: { Image(systemName: "bookmark") }
                        .buttonStyle(.plain).accessibilityLabel("Favorite messages")
                    Button { performForSelectedBackend { if await chat.createConversation() { open = true } } } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).accessibilityLabel("New Chat")
                        .disabled(rowDisabled || chat.loadingModels)
                }
                promptToolbar
            }
            .navigationDestination(isPresented: Binding(get: { open && !sideBySide }, set: { if !sideBySide { open = $0 } })) {
                if loadingChat {
                    ProgressView("Opening chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { Background() }
                        .navigationTitle("Chat")
                } else {
                    ChatView(restoreLatest: false, native: true, inbox: workspace?.runtime(store.activeBackend).inbox)
                        .background { Background() }.toolbar(.hidden, for: .navigationBar)
                }
            }
            .navigationDestination(isPresented: $searching) { ChatSearchView { open = true } }
            .navigationDestination(isPresented: $showingFavorites) { ChatFavoritesView { open = true } }
            .task {
                chat.configure(store)
                captureActiveContacts(); prepareOtherContacts()
                if !openedOnce, workspace?.isOpen(store.activeBackend) == true {
                    open = true
                    if chat.messages.isEmpty { enterChat() }
                }
                if VesperLayout.usesSidebar && !store.token.isEmpty && !open { enterChat() }
                if !store.token.isEmpty { await refreshContacts() }
                if !openedOnce { openedOnce = true }
            }
            .onChange(of: open || searching || showingFavorites) { _, detail in onRootVisibilityChange(!detail) }
            .onChange(of: open) { _, isOpen in
                workspace?.setOpen(isOpen, backend: store.activeBackend)
                if !isOpen {
                    openingTask?.cancel(); openingTask = nil; loadingChat = false
                    Task { await chat.loadConversations(); captureActiveContacts() }
                }
            }
            .onChange(of: chat.conversations) { _, _ in captureActiveContacts() }
            .onChange(of: chat.conversationID) { _, id in
                if !id.isEmpty { windowSelection.wrappedValue = id }
            }
            .onChange(of: store.documents["profile"]) { _, _ in captureActiveContacts() }
            .onChange(of: store.token) { _, _ in
                chat.configure(store); captureActiveContacts(); prepareOtherContacts()
                Task { await refreshContacts() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("VesperConversationOpened"))) { _ in open = true }
    }

    private var promptButton: some View {
        Button { showingChatPrompt = true } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(VesperTheme.ink)
                .frame(width: 44, height: 44)
                .vesperGlass(in: Circle(), interactive: true)
        }.buttonStyle(.plain)
            .accessibilityLabel("Chat prompt").accessibilityIdentifier("chat-prompt-button")
    }
    @ToolbarContentBuilder private var promptToolbar: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { promptButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { promptButton }
        }
        #else
        ToolbarItem(placement: .topBarTrailing) { promptButton }
        #endif
    }

    private var contactsWithDialogs: some View {
        contactsWithNavigation
            .sheet(isPresented: $showingChatPrompt) { ChatPromptEditor() }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deletingConversation != nil }, set: { if !$0 { deletingConversation = nil } }), titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) {
                    guard let item = deletingConversation else { return }
                    deletingConversation = nil
                    deleting = true
                    Task {
                        defer { deleting = false }
                        await chat.removeConversation(item)
                    }
                }
                Button("Cancel", role: .cancel) { deletingConversation = nil }
            } message: {
                Text((deletingConversation?["title"].string ?? "") + "\n" + String((deletingConversation?["preview"].string ?? "").prefix(100)) + "\n\nThis deletes this conversation. Please check the preview before confirming.")
            }
            .alert("Rename conversation", isPresented: Binding(get: { renamingConversation != nil }, set: { if !$0 { renamingConversation = nil } })) {
                TextField("Name", text: $conversationTitle)
                Button("Save") {
                    guard let item = renamingConversation else { return }
                    let title = conversationTitle
                    renamingConversation = nil; renaming = true
                    Task { defer { renaming = false }; await chat.renameConversation(item, title: title) }
                }.disabled(conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { renamingConversation = nil }
            }
            .alert("Edit contact name", isPresented: $editingContactName) {
                TextField("Name", text: $contactName)
                Button("Save") {
                    let name = String(contactName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
                    savingContactName = true
                    Task {
                        defer { savingContactName = false }
                        let saved = await store.mutate("profile", verifySavedValue: true) { current in
                            var profile = current.object
                            profile["agentName"] = .string(name)
                            return .object(profile)
                        }
                        if !saved {
                            chat.error = store.error ?? "The contact name could not be saved."
                            store.error = nil
                        }
                    }
                }.disabled(contactName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Chat", isPresented: Binding(get: { !open && chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK") { chat.error = nil }
            } message: { Text(chat.error ?? "") }
    }

    private func updateWelcomeLine() {
        welcomeLine = ChatWelcomeLines.next(after: welcomeLine)
    }

    private func enterChat(_ item: JSONValue? = nil) {
        guard !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chat.error = "\(store.activeBackend.title) connection is not configured."
            return
        }
        chat.configure(store)
        if (item?.id ?? mainConversationID) == chat.conversationID,
           !chat.messages.isEmpty, !chat.showingCachedHistory {
            open = true; loadingChat = false
            return
        }
        guard !rowDisabled else { return }
        chat.configure(store)
        let previewVisible = chat.previewConversation(item?.id)
        loadingChat = !previewVisible
        open = true
        openingTask = Task {
            let opened: Bool
            if let item { opened = await chat.open(item) }
            else { opened = await chat.openMainRoom() }
            guard !Task.isCancelled else { return }
            openingTask = nil
            loadingChat = false
            if !opened && !chat.showingCachedHistory { open = false }
        }
    }

    private var agentName: String {
        selectedContacts.agentName
    }
    private func captureActiveContacts() {
        backendContacts.capture(store.activeBackend, api: store.api, profile: store.document("profile"), conversations: chat.conversations(for: store.api))
    }
    private func otherClient() throws -> (VesperBackend, APIClient) {
        let backend: VesperBackend = store.activeBackend == .vps ? .mac : .vps
        let connection = BackendConnection.load(backend)
        return (backend, APIClient(baseURL: connection.baseURL, historyURL: connection.historyURL, token: try CredentialStore.load(account: backend.credentialAccount)))
    }
    private func prepareOtherContacts() {
        if let (backend, api) = try? otherClient() { backendContacts.prepare(backend, api: api) }
    }
    private func refreshContacts() async {
        await chat.loadConversations()
        guard !Task.isCancelled else { return }
        captureActiveContacts()
        if let (backend, api) = try? otherClient() { await backendContacts.refresh(backend, api: api) }
    }
    private func performForSelectedBackend(_ action: @escaping @MainActor () async -> Void) {
        guard !rowDisabled else { return }
        guard !store.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            chat.error = "\(store.activeBackend.title) connection is not configured."
            return
        }
        Task { await action() }
    }
    private func beginEditingContactName() {
        contactName = agentName
        editingContactName = true
    }
    private func preview(_ item: JSONValue?, empty: String) -> String {
        guard let item else { return empty }
        let text = item["preview"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? empty : text
    }
    private func conversationRowContent(_ item: JSONValue?, title: String, emptyPreview: String, contacts: ChatBackendContactSnapshot, showBackend: Bool = false) -> some View {
        HStack(spacing: 13) {
            ChatListAvatar(source: contacts.profile["agentAvatar"].string, baseURL: contacts.baseURL)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    if showBackend {
                        Text(contacts.backend == .vps ? "VPS" : "MAC").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3).background(VesperTheme.ink.opacity(0.1), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if let item {
                        Text(ChatPresentation.time(item["updatedAt"].string.isEmpty ? item["createdAt"].string : item["updatedAt"].string))
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }
                Text(preview(item, empty: emptyPreview))
                    .font(.subheadline).foregroundStyle(VesperTheme.muted).lineLimit(1)
            }
        }
    }
}

struct ChatConversationWindow: Identifiable {
    let id: String
    let conversation: JSONValue?
    let title: String
    let isMain: Bool
}

struct ChatBackendContactSnapshot {
    let backend: VesperBackend
    let scope: String
    let baseURL: String
    var profile: JSONValue
    var conversations: [JSONValue]
    var configured: Bool
    var error: String?
    var mainID: String {
        let saved = profile["mainConversationId"].string
        return saved.isEmpty ? conversations.first?.id ?? "" : saved
    }
    var mainConversation: JSONValue? { conversations.first { $0.id == mainID } }
    var agentName: String {
        let name = profile["agentName"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Rowan" : name
    }
    var windows: [ChatConversationWindow] {
        var seen: Set<String> = [mainID]
        return [ChatConversationWindow(id: mainID.isEmpty ? "unconfigured-main" : mainID,
                                       conversation: mainConversation, title: agentName, isMain: true)]
            + conversations.compactMap { room in
                guard !room.id.isEmpty, seen.insert(room.id).inserted else { return nil }
                let title = room["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                return ChatConversationWindow(id: room.id, conversation: room, title: title.isEmpty ? agentName : title, isMain: false)
            }
    }
}

/// Read-only contact previews. Viewing the other card never retargets ChatSession.
@MainActor final class ChatBackendContacts: ObservableObject {
    @Published private(set) var snapshots: [VesperBackend: ChatBackendContactSnapshot] = [:]
    private var revisions: [VesperBackend: UUID] = [:]
    private var clients: [VesperBackend: APIClient] = [:]
    private let cacheRoot: URL?
    private let disk: LocalDocumentDisk
    private let request: (APIClient, String, Bool) async throws -> JSONValue
    init(cacheRoot: URL? = nil, disk: LocalDocumentDisk = LocalDocumentDisk(),
         request: @escaping (APIClient, String, Bool) async throws -> JSONValue = { try await $0.request($1, history: $2) }) {
        self.cacheRoot = cacheRoot; self.disk = disk; self.request = request
    }
    func snapshot(_ backend: VesperBackend) -> ChatBackendContactSnapshot {
        snapshots[backend] ?? ChatBackendContactSnapshot(backend: backend, scope: "", baseURL: BackendConnection.load(backend).baseURL,
                                                       profile: .null, conversations: [], configured: false)
    }
    func client(_ backend: VesperBackend) -> APIClient? { clients[backend] }
    private func file(_ api: APIClient) -> URL? { ChatRecentCache.directory(api: api, root: cacheRoot)?.appendingPathComponent("contacts.json") }
    private func scope(_ api: APIClient) -> String { ChatRecentCache.directory(api: api, root: cacheRoot)?.lastPathComponent ?? "" }
    func prepare(_ backend: VesperBackend, api: APIClient) {
        clients[backend] = api
        guard snapshots[backend]?.scope != scope(api) else { return }
        revisions[backend] = UUID()
        let cached = file(api).flatMap { url -> JSONValue? in
            guard let data = try? Data(contentsOf: url), data.count <= 1_000_000 else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        let local = try? disk.load(api)
        snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                       profile: local?.documents["profile"] ?? cached?["profile"] ?? .null,
                                                       conversations: cached?["conversations"].array ?? [], configured: !api.token.isEmpty)
    }
    func capture(_ backend: VesperBackend, api: APIClient, profile: JSONValue, conversations: [JSONValue]) {
        clients[backend] = api
        revisions[backend] = UUID()
        snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                       profile: profile, conversations: conversations, configured: !api.token.isEmpty)
        save(backend, api: api)
    }
    func refresh(_ backend: VesperBackend, api: APIClient) async {
        prepare(backend, api: api)
        guard !api.token.isEmpty else { return }
        let revision = UUID(); revisions[backend] = revision
        do {
            async let profile = request(api, "/api/state?key=profile", false)
            async let listing = request(api, "/conversations", true)
            let (state, rooms) = try await (profile, listing)
            try Task.checkCancellation()
            guard revisions[backend] == revision, snapshots[backend]?.scope == scope(api) else { return }
            guard case .object = state["value"], case .array(let conversations) = rooms["conversations"] else {
                throw ServiceError(message: "Contact list unavailable.")
            }
            snapshots[backend] = ChatBackendContactSnapshot(backend: backend, scope: scope(api), baseURL: api.baseURL,
                                                           profile: state["value"], conversations: conversations, configured: true)
            save(backend, api: api)
        } catch {
            guard revisions[backend] == revision, !Task.isCancelled, !(error is CancellationError) else { return }
            snapshots[backend]?.error = error.localizedDescription
        }
    }
    private func save(_ backend: VesperBackend, api: APIClient) {
        guard let snapshot = snapshots[backend], let file = file(api) else { return }
        let value: JSONValue = .object(["profile": snapshot.profile, "conversations": .array(snapshot.conversations)])
        guard let data = try? JSONEncoder().encode(value), data.count <= 1_000_000 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct ChatConversationDeck<Content: View>: View {
    let windows: [ChatConversationWindow]
    @Binding var selected: String
    @ViewBuilder var card: (ChatConversationWindow) -> Content
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var index: Int { windows.firstIndex { $0.id == selected } ?? 0 }
    private func flip(_ direction: Int) {
        guard windows.count > 1 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.85)) {
            selected = windows[(index + direction + windows.count) % windows.count].id
        }
    }
    var body: some View {
        if !windows.isEmpty {
        VStack(spacing: 5) {
        ZStack {
            ForEach(Array(1..<min(windows.count, 3)).reversed(), id: \.self) { depth in
                card(windows[(index + depth) % windows.count]).mask(alignment: .top) { Rectangle().frame(height: 14) }
                    .scaleEffect(x: 1 - CGFloat(depth) * 0.05, y: 0.95, anchor: .top).offset(y: -CGFloat(depth) * 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            card(windows[index]).id(windows[index].id).offset(y: drag)
        }.padding(.top, windows.count > 2 ? 28 : windows.count > 1 ? 18 : 0).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 14)
                .updating($drag) { value, state, _ in
                    if abs(value.translation.height) > abs(value.translation.width) * 1.25 {
                        state = min(12, max(-12, value.translation.height / 4))
                    }
                }
                .onEnded { value in
                    if abs(value.translation.height) >= 28, abs(value.translation.height) > abs(value.translation.width) * 1.25 {
                        flip(value.translation.height < 0 ? 1 : -1)
                    }
                }, including: windows.count > 1 ? .all : .none)
            if windows.count > 1 {
                Text("\(index + 1) / \(windows.count)").font(.caption2).monospacedDigit().foregroundStyle(VesperTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10).accessibilityHidden(true)
            }
        }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Conversation windows")
            .accessibilityValue("\(index + 1) of \(windows.count)")
            .accessibilityAction(named: Text("Next conversation")) { flip(1) }
            .accessibilityAction(named: Text("Previous conversation")) { flip(-1) }
            .accessibilityIdentifier("chat-conversation-deck")
        }
    }
}

/// Local decorative greetings rotate on entry; they do not create chat messages.
enum ChatWelcomeLines {
    static let all = [
        "A place for today, too.",
        "Come as you are.",
        "A little room for us.",
        "There’s room for your whole day.",
        "Hello again, lovely you.",
        "Leave a little of today here.",
        "One thought, or a thousand.",
        "A quiet place to begin.",
        "We can take our time.",
        "For all the little things.",
        "A little closer, a little softer.",
        "No perfect words needed.",
        "Something to tell, something to keep.",
        "The day can wait a moment.",
        "Let’s make a little space.",
        "Here, with you."
    ]
    static func next(after previous: String) -> String {
        all.filter { $0 != previous }.randomElement() ?? all[0]
    }
}

struct ChatFavoritesView: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var selected: () -> Void
    @State private var query = ""
    @State private var error = ""
    @State private var opening = false

    private var favorites: [JSONValue] {
        store.document("favorites").array.filter {
            query.isEmpty || $0["content"].string.localizedCaseInsensitiveContains(query)
                || $0["conversationTitle"].string.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if favorites.isEmpty && error.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No favorite messages yet" : "No matching messages",
                                       systemImage: "bookmark", description: Text(query.isEmpty ? "Bookmark a message in chat to keep it here." : "Try another search."))
                    .listRowBackground(Color.clear)
            }
            ForEach(favorites) { item in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(item["role"].string == "user" ? "You" : (store.document("profile")["agentName"].string.isEmpty ? "Rowan" : store.document("profile")["agentName"].string))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(ChatPresentation.time(item["createdAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    ChatMarkdownText(content: item["content"].string).font(.subheadline).lineLimit(6)
                    Button {
                        opening = true
                        Task {
                            let opened = await chat.openSearchResult(.object([
                                "id": item["metadata"]["sourceMessageId"].string.isEmpty ? item["messageId"] : item["metadata"]["sourceMessageId"], "conversationId": item["conversationId"]
                            ]))
                            opening = false
                            if opened { dismiss(); selected() }
                            else { error = chat.error ?? "Could not open this message."; chat.error = nil }
                        }
                    } label: { Label("Open message", systemImage: "arrow.up.right") }
                        .font(.caption.weight(.semibold)).disabled(opening || chat.busy || chat.callActive)
                }
                .padding(.vertical, 7)
                .swipeActions {
                    Button(role: .destructive) { Task { _ = await store.remove("favorites", id: item.id) } } label: {
                        Label("Remove favorite", systemImage: "bookmark.slash")
                    }.disabled(store.saving)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).transparentNavigationTop()
        .background { Background() }
        .navigationTitle("Favorites").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search favorites")
        .refreshable { await store.refresh() }
    }
}

private extension View {
    func contactGlassSurface(verticalPadding: CGFloat = 15) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .padding(.horizontal, 16).padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
.vesperGlass(in: shape, interactive: true)
    }
}

private struct ChatListAvatar: View {
    let source: String
    let baseURL: String
    var body: some View {
        Group {
            if source.hasPrefix("data:image/"),
               let comma = source.firstIndex(of: ","),
               let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !source.isEmpty,
                      let url = URL(string: source, relativeTo: URL(string: baseURL))?.absoluteURL,
                      url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(VesperTheme.muted.opacity(0.19))
            Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(VesperTheme.muted)
        }
    }
}
struct ChatSearchView: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var selected: () -> Void
    @State private var query = ""
    @State private var scope = "All chats"
    @State private var results: [JSONValue] = []
    @State private var busy = false
    @State private var error = ""
    @State private var hasMore = false
    @State private var searchNotice = ""
    var body: some View {
        List {
            Picker("Search in", selection: $scope) { Text("All chats").tag("All chats"); Text("This chat").tag("This chat") }.pickerStyle(.segmented)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if !searchNotice.isEmpty { Text(searchNotice).font(.caption).foregroundStyle(VesperTheme.muted) }
            if busy { ProgressView() }
            ForEach(results) { message in
                Button { Task {
                    guard await chat.openSearchResult(message) else { error = chat.error ?? "Could not open this message."; chat.error = nil; return }
                    dismiss(); selected()
                } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message["title"].string).font(.headline)
                        Text(highlightedSnippet(message["content"].string)).font(.subheadline).lineLimit(4)
                        Text(ChatPresentation.time(message["createdAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }.disabled(chat.busy)
            }
            if hasMore { Button("More results") { Task { await search(more: true) } }.disabled(busy) }
            if !busy && results.isEmpty && !query.isEmpty && error.isEmpty && searchNotice.isEmpty { Text("No matching messages.").foregroundStyle(VesperTheme.muted) }
        }.scrollContentBackground(.hidden).transparentNavigationTop().background { Background() }.navigationTitle("Search")
        .searchable(text: $query, prompt: "Words from a conversation")
        .task(id: query + "\u{0}" + scope) {
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await search()
        }
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: scope) { _, _ in Task { await search() } }
    }
    private func snippet(_ text: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(240)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...].prefix(240))
    }
    private func highlightedSnippet(_ text: String) -> AttributedString {
        var result = AttributedString(snippet(text))
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, let range = result.range(of: term, options: .caseInsensitive) {
            result[range].foregroundColor = .blue
            result[range].font = .body.bold()
        }
        return result
    }
    private func search(more: Bool = false) async {
        if more && busy { return }
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedScope = scope
        busy = true
        defer { if requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope { busy = false } }
        if !more { results = []; hasMore = false; error = ""; searchNotice = "" }
        guard !requested.isEmpty else { results = []; hasMore = false; error = ""; searchNotice = ""; return }
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: requested), URLQueryItem(name: "conversationId", value: scope == "This chat" ? chat.conversationID : ""), URLQueryItem(name: "offset", value: String(more ? results.count : 0))]
            let response = try await store.api.request("/search?" + (params.percentEncodedQuery ?? ""), history: true)
            guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            results = more ? results + response["results"].array : response["results"].array
            hasMore = response["hasMore"].bool; error = ""; searchNotice = ""
        } catch let failure as ServiceError where failure.statusCode == 404 {
            guard !Task.isCancelled, requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            await legacySearch(requested, scope: requestedScope)
        } catch {
            guard !Task.isCancelled, requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            self.error = error.localizedDescription
        }
    }
    private func legacySearch(_ requested: String, scope requestedScope: String) async {
        do {
            let response = try await store.api.request("/conversations", history: true)
            let conversations = response["conversations"].array.filter { requestedScope != "This chat" || $0.id == chat.conversationID }
            var matches: [JSONValue] = []
            var limited = false
            var failed = 0
            for conversation in conversations {
                guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
                let page: JSONValue
                do { page = try await store.api.request("/conversations/" + conversation.id, history: true) }
                catch { failed += 1; continue }
                let messages = page["messages"].array
                if messages.count >= 1000 || page["hasMore"].bool { limited = true }
                for message in messages where message["content"].string.localizedCaseInsensitiveContains(requested) {
                    var fields = message.object
                    fields["conversationId"] = .string(conversation.id)
                    fields["title"] = conversation["title"]
                    matches.append(.object(fields))
                }
            }
            guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            results = matches; hasMore = false; error = ""
            if failed > 0 {
                searchNotice = "\(failed) conversation(s) could not be read. These results are incomplete."
                return
            }
            searchNotice = limited ? "Compatibility search: the server may return only the first 1,000 messages per chat. Update the history service for complete search." : "Compatibility search of saved chats. Update the history service to enable the dedicated search endpoint."
        } catch { self.error = "Could not search saved history: " + error.localizedDescription }
    }
}
