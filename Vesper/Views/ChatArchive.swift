import SwiftUI

struct NativeChatHome: View {
    var onMenu: (() -> Void)? = nil
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @State private var open = false
    @State private var openedOnce = false
    @State private var deletingConversation: JSONValue?
    @State private var deleting = false
    @State private var renamingConversation: JSONValue?
    @State private var conversationTitle = ""
    @State private var renaming = false
    var body: some View {
        NavigationStack {
            List {
                Button { Task { if await chat.openMainRoom() { open = true } } } label: { Label("Main room", systemImage: "house") }
                Button { Task { if await chat.createConversation() { open = true } } } label: { Label("New Chat", systemImage: "plus") }
                NavigationLink { ChatSearchView { open = true } } label: { Label("Search messages", systemImage: "magnifyingglass") }
                Section("Conversations") {
                    ForEach(chat.conversations) { item in
                        Button { Task { if await chat.open(item) { open = true } } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item["title"].string).font(.headline)
                                Text(item["preview"].string).lineLimit(2).font(.subheadline)
                                Text(ChatPresentation.time(item["updatedAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { conversationTitle = item["title"].string; renamingConversation = item } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                            Button(role: .destructive) { deletingConversation = item } label: { Label("Delete", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { conversationTitle = item["title"].string; renamingConversation = item } label: { Label("Rename conversation", systemImage: "pencil") }
                            Button(role: .destructive) { deletingConversation = item } label: { Label("Delete conversation", systemImage: "trash") }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).transparentNavigationTop().background { Background() }
            .disabled(chat.busy || chat.openingMainRoom || chat.callActive || deleting || renaming)
            .navigationTitle("Chat").toolbar {
                ToolbarItem(placement: .topBarLeading) { if let onMenu { Button(action: onMenu) { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") } }
                ToolbarItem(placement: .topBarTrailing) { AppearancePicker() } }
            .navigationDestination(isPresented: $open) {
                ChatView(restoreLatest: false, native: true)
                    .background { Background() }.toolbar(.hidden, for: .navigationBar)
            }
            .task {
                chat.configure(store); await chat.loadConversations()
                if !openedOnce { openedOnce = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("VesperConversationOpened"))) { _ in open = true }
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
                Text("This deletes the conversation from Vesper history and cannot be undone. Copies stored separately by Codex are not deleted.")
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
            .alert("Chat", isPresented: Binding(get: { !open && chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK") { chat.error = nil }
            } message: { Text(chat.error ?? "") }
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
                    if chat.conversationID != message["conversationId"].string {
                        guard await chat.open(.object(["id": message["conversationId"]])) else { error = chat.error ?? "Could not open this conversation."; chat.error = nil; return }
                    }
                    await chat.reveal(message.id); dismiss(); selected()
                } } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message["title"].string).font(.headline)
                        Text(snippet(message["content"].string)).font(.subheadline).lineLimit(4)
                        Text(ChatPresentation.time(message["createdAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }.disabled(chat.busy)
            }
            if hasMore { Button("More results") { Task { await search(more: true) } }.disabled(busy) }
            if !busy && results.isEmpty && !query.isEmpty && error.isEmpty { Text("No matching messages.").foregroundStyle(VesperTheme.muted) }
        }.scrollContentBackground(.hidden).transparentNavigationTop().background { Background() }.navigationTitle("Search")
        .searchable(text: $query, prompt: "Words from a conversation")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: scope) { _, _ in Task { await search() } }
    }
    private func snippet(_ text: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(240)) }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        return (start > text.startIndex ? "…" : "") + String(text[start...].prefix(240))
    }
    private func search(more: Bool = false) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let requested = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { results = []; hasMore = false; error = ""; searchNotice = ""; return }
        let requestedScope = scope
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: requested), URLQueryItem(name: "conversationId", value: scope == "This chat" ? chat.conversationID : ""), URLQueryItem(name: "offset", value: String(more ? results.count : 0))]
            let response = try await store.api.request("/search?" + (params.percentEncodedQuery ?? ""), history: true)
            guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
            results = more ? results + response["results"].array : response["results"].array
            hasMore = response["hasMore"].bool; error = ""; searchNotice = ""
        } catch let failure as ServiceError where failure.statusCode == 404 {
            await legacySearch(requested, scope: requestedScope)
        } catch { self.error = error.localizedDescription }
    }
    private func legacySearch(_ requested: String, scope requestedScope: String) async {
        do {
            let response = try await store.api.request("/conversations", history: true)
            let conversations = response["conversations"].array.filter { requestedScope != "This chat" || $0.id == chat.conversationID }
            var matches: [JSONValue] = []
            var limited = false
            for conversation in conversations {
                guard requested == query.trimmingCharacters(in: .whitespacesAndNewlines), requestedScope == scope else { return }
                let page = try await store.api.request("/conversations/" + conversation.id, history: true)
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
            searchNotice = limited ? "Compatibility search: the server may return only the first 1,000 messages per chat. Update the history service for complete search." : "Compatibility search of saved chats. Update the history service to enable the dedicated search endpoint."
        } catch { self.error = "Could not search saved history: " + error.localizedDescription }
    }
}

