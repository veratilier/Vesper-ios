import SwiftUI

struct NativeChatHome: View {
    var onMenu: (() -> Void)? = nil
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @State private var open = false
    @State private var loadingChat = false
    @State private var openingTask: Task<Void, Never>?
    @State private var searching = false
    @State private var openedOnce = false
    @State private var deletingConversation: JSONValue?
    @State private var deleting = false
    @State private var renamingConversation: JSONValue?
    @State private var conversationTitle = ""
    @State private var renaming = false
    @State private var editingContactName = false
    @State private var contactName = ""
    @State private var savingContactName = false
    private var mainConversationID: String {
        let saved = store.document("profile")["mainConversationId"].string
        return saved.isEmpty ? (chat.conversations.first?.id ?? "") : saved
    }
    private var mainConversation: JSONValue? { chat.conversations.first { $0.id == mainConversationID } }
    private var otherConversations: [JSONValue] { chat.conversations.filter { $0.id != mainConversationID } }
    private var rowDisabled: Bool { loadingChat || chat.busy || chat.openingMainRoom || chat.callActive || deleting || renaming || savingContactName }
    var body: some View {
        NavigationStack {
            List {
                Button { searching = true } label: {
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

                Button { enterChat() } label: {
                    conversationRow(mainConversation, title: agentName, emptyPreview: "Start chatting")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { beginEditingContactName() } label: { Label("Edit name", systemImage: "pencil") }.tint(.blue)
                }
                .contextMenu {
                    Button { beginEditingContactName() } label: { Label("Edit contact name", systemImage: "pencil") }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel("\(agentName), \(preview(mainConversation, empty: "Start chatting"))")

                ForEach(otherConversations) { item in
                    Button { enterChat(item) } label: {
                        conversationRow(item, title: item["title"].string.isEmpty ? agentName : item["title"].string, emptyPreview: "No messages yet")
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { conversationTitle = item["title"].string; renamingConversation = item } label: { Label("Rename", systemImage: "pencil") }.tint(.blue)
                        Button(role: .destructive) { deletingConversation = item } label: { Label("Delete", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button { conversationTitle = item["title"].string; renamingConversation = item } label: { Label("Rename conversation", systemImage: "pencil") }
                        Button(role: .destructive) { deletingConversation = item } label: { Label("Delete conversation", systemImage: "trash") }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }.scrollContentBackground(.hidden).transparentNavigationTop().background { Background() }
            .listStyle(.plain)
            .refreshable { await chat.loadConversations() }
            .disabled(rowDisabled)
            .navigationTitle("Chat").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .topBarLeading) { if let onMenu { Button(action: onMenu) { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { if await chat.createConversation() { open = true } } } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New Chat")
                        .disabled(rowDisabled || chat.loadingModels)
                }
            }
            .navigationDestination(isPresented: $open) {
                if loadingChat {
                    ProgressView("Opening chat…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { Background() }
                        .navigationTitle("Chat")
                } else {
                    ChatView(restoreLatest: false, native: true)
                        .background { Background() }.toolbar(.hidden, for: .navigationBar)
                }
            }
            .navigationDestination(isPresented: $searching) { ChatSearchView { open = true } }
            .task {
                chat.configure(store); await chat.loadConversations()
                if !openedOnce { openedOnce = true }
            }
            .onChange(of: open) { _, isOpen in
                if !isOpen {
                    openingTask?.cancel(); openingTask = nil; loadingChat = false
                    Task { await chat.loadConversations() }
                }
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
    }

    private func enterChat(_ item: JSONValue? = nil) {
        guard !rowDisabled else { return }
        loadingChat = true
        open = true
        openingTask = Task {
            let opened: Bool
            if let item { opened = await chat.open(item) }
            else { opened = await chat.openMainRoom() }
            guard !Task.isCancelled else { return }
            openingTask = nil
            loadingChat = false
            if !opened { open = false }
        }
    }

    private var agentName: String {
        let name = store.document("profile")["agentName"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Rowan" : name
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
    private func conversationRow(_ item: JSONValue?, title: String, emptyPreview: String) -> some View {
        HStack(spacing: 13) {
            ChatListAvatar(source: store.document("profile")["agentAvatar"].string, baseURL: store.baseURL)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
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
        .contactGlassSurface()
        .contentShape(Rectangle())
    }
}

private extension View {
    func contactGlassSurface(verticalPadding: CGFloat = 15) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return self
            .padding(.horizontal, 16).padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(Color(red: 0.45, green: 0.66, blue: 0.86)
                            .opacity(VesperTheme.palette == .blue ? 0.15 : 0.03))
                    }
            }
            .overlay(shape.strokeBorder(.white.opacity(VesperTheme.palette == .black ? 0.24 : 0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.09), radius: 12, y: 5)
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
