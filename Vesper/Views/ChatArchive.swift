import SwiftUI

struct NativeChatHome: View {
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @State private var open = false
    @State private var openedOnce = false
    var body: some View {
        NavigationStack {
            List {
                Button { Task { await chat.openMainRoom(); open = true } } label: { Label("Main room", systemImage: "house") }
                Button { Task { if await chat.createConversation() { open = true } } } label: { Label("New Chat", systemImage: "plus") }
                NavigationLink { ChatSearchView { open = true } } label: { Label("Search messages", systemImage: "magnifyingglass") }
                Section("Conversations") {
                    ForEach(chat.conversations) { item in
                        Button { Task { await chat.open(item); open = true } } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(item["title"].string).font(.headline)
                                Text(item["preview"].string).lineLimit(2).font(.subheadline)
                                Text(ChatPresentation.time(item["updatedAt"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background { Background() }
            .disabled(chat.busy || chat.callActive)
            .navigationTitle("Chat").toolbar { ToolbarItem(placement: .topBarTrailing) { AppearancePicker() } }
            .navigationDestination(isPresented: $open) {
                ChatView(restoreLatest: false, native: true)
                    .background { Background() }.navigationTitle("Chat").navigationBarTitleDisplayMode(.inline)
            }
            .task {
                chat.configure(store); await chat.loadConversations()
                if !openedOnce { openedOnce = true; if chat.messages.isEmpty && !chat.conversations.contains(where: { $0.id == chat.conversationID }) { await chat.openMainRoom() }; open = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("VesperOpenConversation"))) { _ in open = true }
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
    var body: some View {
        List {
            Picker("Search in", selection: $scope) { Text("All chats").tag("All chats"); Text("This chat").tag("This chat") }.pickerStyle(.segmented)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if busy { ProgressView() }
            ForEach(results) { message in
                Button { Task {
                    if chat.conversationID != message["conversationId"].string { await chat.open(.object(["id": message["conversationId"]])) }
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
        }.scrollContentBackground(.hidden).background { Background() }.navigationTitle("Search")
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
        let requested = query
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: requested), URLQueryItem(name: "conversationId", value: scope == "This chat" ? chat.conversationID : ""), URLQueryItem(name: "offset", value: String(more ? results.count : 0))]
            let response = try await store.api.request("/search?" + (params.percentEncodedQuery ?? ""), history: true)
            guard requested == query else { return }
            results = more ? results + response["results"].array : response["results"].array
            hasMore = response["hasMore"].bool; error = ""
        } catch { self.error = error.localizedDescription }
    }
}
