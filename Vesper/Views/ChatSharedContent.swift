import SwiftUI
import SafariServices
import UniformTypeIdentifiers

enum ChatWebURL {
    static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") &&
        !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}

struct ChatInAppLinks: ViewModifier {
    private struct Page: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
    @State private var page: Page?
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard ChatWebURL.accepts(url) else { return .systemAction }
            page = Page(url: url)
            return .handled
        })
        .sheet(item: $page) { ChatBrowser(url: $0.url, onDone: { page = nil }).ignoresSafeArea() }
    }
}

private struct ChatBrowser: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done: onDone) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.delegate = context.coordinator
        return browser
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) { context.coordinator.done = onDone }
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        var done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { done() }
    }
}

struct ChatFileCard: View {
    let attachment: JSONValue
    private var name: String { attachment["name"].string.isEmpty ? "Shared file" : attachment["name"].string }
    static func typeLabel(name: String, mime: String) -> String {
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { return String(ext.prefix(12)).uppercased() }
        return UTType(mimeType: mime)?.localizedDescription ?? "File"
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: attachment["type"].string == "application/pdf" ? "doc.richtext" : "doc.text")
                .font(.title2).foregroundStyle(VesperTheme.accent)
                .frame(width: 44, height: 52).background(VesperTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(Self.typeLabel(name: name, mime: attachment["type"].string) + " · " +
                     ByteCountFormatter.string(fromByteCount: Int64(max(0, attachment["size"].number)), countStyle: .file))
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(VesperTheme.muted)
        }.padding(14).frame(maxWidth: 280, alignment: .leading)
            .vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine).accessibilityHint("Preview file")
    }
}

struct ChatMessageAction: Identifiable {
    let title: String
    let icon: String
    let run: () -> Void
    var id: String { title }
}

@MainActor final class ChatActionMenu: ObservableObject {
    struct Selection {
        let id: String
        let frame: CGRect
        let actions: [ChatMessageAction]
    }
    @Published var selection: Selection?
    func show(id: String, frame: CGRect, actions: [ChatMessageAction]) {
        guard !frame.isEmpty, !actions.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        selection = Selection(id: id, frame: frame, actions: actions)
    }
}

struct ChatLongPress: ViewModifier {
    let id: String
    let actions: () -> [ChatMessageAction]
    var onTap: (() -> Void)? = nil
    @EnvironmentObject private var menu: ChatActionMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = CGRect.zero
    private var isSelected: Bool { menu.selection?.id == id }
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                // Keep the menu anchored to the resting position throughout the lift.
                if !isSelected { frame = $0 }
            }
            .contentShape(Rectangle())
            .modifier(ChatPressGesture(onTap: onTap) { menu.show(id: id, frame: frame, actions: actions()) })
            #if targetEnvironment(macCatalyst)
            .contextMenu {
                ForEach(actions()) { action in Button(action.title, action: action.run) }
            }
            #endif
            .accessibilityActions {
                ForEach(actions()) { action in Button(action.title, action: action.run) }
            }
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: isSelected ? 8 : 0, y: isSelected ? 4 : 0)
            .scaleEffect(isSelected && !reduceMotion ? 1.012 : 1)
            .offset(y: isSelected && !reduceMotion ? -2 : 0)
            .zIndex(isSelected ? 1 : 0)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: isSelected)
    }
}

private struct ChatPressGesture: ViewModifier {
    let onTap: (() -> Void)?
    let onHold: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if let onTap {
            content.highPriorityGesture(
                LongPressGesture(minimumDuration: 0.35, maximumDistance: 22)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first(true): onHold()
                        case .second: onTap()
                        default: break
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onTap() }
        } else {
            content.onLongPressGesture(minimumDuration: 0.35, maximumDistance: 22, perform: onHold)
        }
    }
}

struct ChatActionOverlay: View {
    @ObservedObject var menu: ChatActionMenu
    var body: some View {
        GeometryReader { geometry in
            if let selection = menu.selection {
                let origin = geometry.frame(in: .global).origin
                let width = min(CGFloat(selection.actions.count) * 70, geometry.size.width - 24)
                let x = min(max(selection.frame.midX - origin.x, width / 2 + 12), geometry.size.width - width / 2 - 12)
                let above = selection.frame.minY - origin.y - 42
                let y = above >= 36 ? above : min(selection.frame.maxY - origin.y + 42, geometry.size.height - 40)
                Color.black.opacity(0.025).contentShape(Rectangle())
                    .onTapGesture { menu.selection = nil }
                    .accessibilityLabel("关闭消息菜单").accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                HStack(spacing: 0) {
                    ForEach(selection.actions) { action in
                        Button {
                            menu.selection = nil
                            action.run()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: action.icon).font(.system(size: 19))
                                Text(action.title).font(.system(size: 12))
                            }.frame(maxWidth: .infinity).frame(height: 62).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .foregroundStyle(VesperTheme.ink)
                .frame(width: width)
                .vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .position(x: x, y: y)
                .accessibilityIdentifier("chat-message-actions")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: menu.selection?.id)
    }
}

struct ChatQuotePreview: View {
    let quote: JSONValue
    var onOpen: (() -> Void)? = nil
    var body: some View {
        Button { onOpen?() } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(VesperTheme.muted.opacity(0.6)).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ChatPresentation.isUser(quote) ? "Vera" : "Rowan").font(.caption.weight(.semibold))
                    Text(quote["text"].string).font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(10)
                .background(VesperTheme.muted.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(VesperTheme.muted)
            .accessibilityHint("跳回被引用的消息")
    }
}

struct ChatBubbleSurface: ViewModifier {
    let user: Bool
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: user ? 20 : 5,
                                           bottomTrailingRadius: user ? 5 : 20, topTrailingRadius: 20)
        content.padding(.horizontal, 14).padding(.vertical, 11)
            .background(user ? VesperTheme.accent.opacity(0.10) : Color.clear, in: shape)
            .vesperGlass(in: shape)
    }
}

// Space indexes attachment metadata only. Opening chat and sending messages never run this scan.
struct ChatSpaceItem: Codable, Identifiable, Equatable {
    let id: String
    let conversationID: String
    let conversationTitle: String
    let messageID: String
    let date: String
    let fromVera: Bool
    let attachment: JSONValue
    var name: String { attachment["name"].string.isEmpty ? "Shared file" : attachment["name"].string }
    var kind: String {
        let mime = attachment["type"].string.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(ext) { return "Images" }
        if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "ogg"].contains(ext) { return "Audio" }
        if mime.hasPrefix("video/") || ["mp4", "mov", "webm"].contains(ext) { return "Videos" }
        return "Files"
    }
    var symbol: String { kind == "Images" ? "photo" : kind == "Audio" ? "waveform" : kind == "Videos" ? "film" : "doc.text" }
    var url: URL? {
        guard let value = URL(string: attachment["url"].string), value.scheme == "https", ChatWebURL.accepts(value) else { return nil }
        return value
    }
    static func extract(messages: [JSONValue], room: JSONValue, tombstones: [JSONValue]) -> [Self] {
        messages.filter { !ChatTranscript.isDeleted($0, tombstones: tombstones) }.flatMap { message in
            message["metadata"]["attachments"].array.enumerated().compactMap { index, attachment in
                let item = Self(id: room.id + ":" + message.id + ":" + String(index), conversationID: room.id,
                                conversationTitle: room["title"].string, messageID: message.id,
                                date: ChatTranscript.timestamp(message), fromVera: ChatPresentation.isUser(message), attachment: attachment)
                return item.url == nil ? nil : item
            }
        }
    }
}

@MainActor final class ChatSpaceIndex: ObservableObject {
    struct Room: Codable { var revision: String; var items: [ChatSpaceItem] }
    @Published private(set) var items: [ChatSpaceItem] = []
    @Published private(set) var loading = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?
    private var rooms: [String: Room] = [:]
    private let api: APIClient
    private let file: URL?
    private let request: (String) async throws -> JSONValue
    init(api: APIClient, cacheURL: URL? = nil, request: ((String) async throws -> JSONValue)? = nil) {
        self.api = api
        file = cacheURL ?? ChatRecentCache.directory(api: api)?.appendingPathComponent("space-index.json")
        self.request = request ?? { try await api.request($0, history: true) }
        if let file, let data = try? Data(contentsOf: file), data.count <= 30_000_000,
           let cached = try? JSONDecoder().decode([String: Room].self, from: data) { rooms = cached }
        publish()
    }
    private func publish(extra: [ChatSpaceItem] = [], replacing: String? = nil) {
        let all = rooms.filter { $0.key != replacing }.values.flatMap(\.items) + extra
        items = Array(Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }).values)
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(rooms).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { self.error = "Files loaded, but the local index could not be saved." }
    }
    func refresh(force: Bool = false, conversationIDs: Set<String>? = nil) async {
        guard !loading, !api.token.isEmpty else { return }
        loading = true; error = nil; progress = "Looking for shared files…"
        defer { loading = false; progress = ""; publish() }
        do {
            let listing = try await request("/conversations")
            guard case .array(let conversations) = listing["conversations"] else { throw ServiceError(message: "Conversation list unavailable.") }
            try Task.checkCancellation()
            let ids = Set(conversations.map(\.id))
            rooms = rooms.filter { ids.contains($0.key) }; publish(); persist()
            var failed = 0
            var firstFailure = ""
            let targets = conversations.filter { conversationIDs?.contains($0.id) ?? true }
            for (index, room) in targets.enumerated() {
                try Task.checkCancellation()
                let revision = room["updatedAt"].string
                if !force, !revision.isEmpty, rooms[room.id]?.revision == revision { continue }
                progress = "整理附件 · \(index + 1)/\(targets.count) 个对话"
                do {
                    var cursor = "", seen: Set<String> = [], collected: [ChatSpaceItem] = []
                    while true {
                        try Task.checkCancellation()
                        var query = URLComponents()
                        query.queryItems = [URLQueryItem(name: "latest", value: "1"), URLQueryItem(name: "limit", value: "200")]
                        if !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
                        let escaped = room.id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
                        let page = try await request("/conversations/" + escaped + "?" + (query.percentEncodedQuery ?? ""))
                        try Task.checkCancellation()
                        try ChatSession.validateHistoryRecord(page, expectedID: room.id)
                        guard case .array(let messages) = page["messages"] else { throw ServiceError(message: "Message page unavailable.") }
                        collected += ChatSpaceItem.extract(messages: messages, room: room, tombstones: page["tombstones"].array)
                        publish(extra: collected, replacing: room.id)
                        if !page["hasMore"].bool { break }
                        cursor = page["before"].string
                        guard !cursor.isEmpty, seen.insert(cursor).inserted else { throw ServiceError(message: "History pagination stopped before all files were indexed.") }
                    }
                    rooms[room.id] = Room(revision: revision, items: collected); publish(); persist()
                } catch is CancellationError { throw CancellationError() }
                catch let failure as ServiceError where failure.conversationDeleted {
                    rooms.removeValue(forKey: room.id); publish(); persist()
                } catch {
                    failed += 1
                    if firstFailure.isEmpty { firstFailure = error.localizedDescription }
                    publish()
                }
            }
            if failed > 0 { error = "\(failed) 个对话的附件未更新，已保留可用内容。可下拉重试。\n" + firstFailure }
        } catch is CancellationError { }
        catch { self.error = "附件索引暂未更新：" + error.localizedDescription }
    }
}

struct ChatSpaceView: View {
    @StateObject private var index: ChatSpaceIndex
    @State private var filter = "All"
    @State private var sender = "Everyone"
    @State private var query = ""
    @State private var preview: ChatSpaceItem?
    let conversationIDs: Set<String>?
    let embedded: Bool
    let showMessage: (ChatSpaceItem) -> Void
    init(api: APIClient, conversationIDs: Set<String>? = nil, embedded: Bool = false, showMessage: @escaping (ChatSpaceItem) -> Void) {
        _index = StateObject(wrappedValue: ChatSpaceIndex(api: api)); self.showMessage = showMessage
        self.conversationIDs = conversationIDs; self.embedded = embedded
    }
    private var visible: [ChatSpaceItem] {
        index.items.filter {
            (conversationIDs?.contains($0.conversationID) ?? true) &&
            (filter == "All" || $0.kind == filter) &&
            (sender == "Everyone" || (sender == "Vera" ? $0.fromVera : !$0.fromVera)) &&
            (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.conversationTitle.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["All", "Images", "Files", "Audio", "Videos"], id: \.self) { category in
                        Button { filter = category } label: {
                            Text(category).chatNavigationFont().padding(.horizontal, 12).frame(minHeight: 40)
                                .background(filter == category ? VesperTheme.ink.opacity(0.12) : .clear, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(filter == category ? .isSelected : [])
                    }
                }.padding(.horizontal, 16)
            }.padding(.vertical, 8)
            List {
                if index.loading { HStack { ProgressView(); Text(index.progress).font(.caption) }.listRowBackground(Color.clear) }
                if let error = index.error { Text(error).font(.caption).foregroundStyle(VesperTheme.muted).listRowBackground(Color.clear) }
                ForEach(visible) { item in
                    Button { preview = item } label: {
                        HStack(spacing: 14) {
                            Group {
                                if item.kind == "Images", let url = item.url {
                                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "photo") }
                                } else { Image(systemName: item.symbol).font(.title2).foregroundStyle(VesperTheme.accent) }
                            }.frame(width: 40, height: 40).clipped()
                                .vesperGlass(in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name).chatNavigationFont(14, weight: .medium).lineLimit(2)
                                Text((item.fromVera ? "Vera" : "Rowan") + " · " + ChatPresentation.time(item.date))
                                    .chatNavigationFont(12, weight: .regular).foregroundStyle(VesperTheme.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(.plain).listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .contextMenu { Button { showMessage(item) } label: { Label("Show in chat", systemImage: "bubble.left") } }
                }
                if visible.isEmpty && !index.loading {
                    ContentUnavailableView(query.isEmpty ? "No shared files" : "No matches", systemImage: "tray",
                                           description: Text(index.items.isEmpty ? "你和 Rowan 在这个联系人的聊天中发过的文件会出现在这里。" : "Try another type, sender, or search."))
                        .listRowBackground(Color.clear)
                }
            }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await index.refresh(force: true, conversationIDs: conversationIDs) }
        }.foregroundStyle(VesperTheme.ink).background { Background() }
            .modifier(SpaceNavigationTitle(embedded: embedded))
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                    TextField("Search files", text: $query).chatNavigationFont(14, weight: .regular).accessibilityIdentifier("space-search")
                    Menu {
                        Picker("Sent by", selection: $sender) {
                            ForEach(["Everyone", "Vera", "Rowan"], id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Image(systemName: sender == "Everyone" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill").frame(width: 40, height: 40) }
                        .accessibilityLabel("Filter by sender").accessibilityValue(sender)
                }.padding(.horizontal, 16).padding(.vertical, 6).vesperGlass(in: Capsule()).padding(16)
            }
            .sheet(item: $preview) { item in
                if let url = item.url { ChatAttachmentPreview(url: url, name: item.name) }
            }
            .task(id: conversationIDs) { await index.refresh(conversationIDs: conversationIDs) }
    }
}

private struct ChatNavigationFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    init(size: CGFloat, weight: Font.Weight) { _size = ScaledMetric(wrappedValue: size, relativeTo: .subheadline); self.weight = weight }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}
extension View {
    func chatNavigationFont(_ size: CGFloat = 14, weight: Font.Weight = .medium) -> some View {
        modifier(ChatNavigationFont(size: size, weight: weight))
    }
}

struct ChatProjectPage<Chats: View, Sources: View>: View {
    let project: ChatProject
    @Binding var tab: String
    @Binding var draft: String
    let canSend: Bool
    let newChat: () -> Void
    let send: () -> Void
    @ViewBuilder var chats: () -> Chats
    @ViewBuilder var sources: () -> Sources
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(["Chats", "Sources"], id: \.self) { value in
                    Button { tab = value } label: {
                        Text(value).chatNavigationFont(14, weight: .medium)
                            .foregroundStyle(tab == value ? VesperTheme.ink : VesperTheme.muted)
                            .padding(.horizontal, 16).frame(minHeight: 40)
                            .background(tab == value ? VesperTheme.ink.opacity(0.08) : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.top, 8)
            if tab == "Chats" { chats() } else { sources() }
        }.background { Background() }.foregroundStyle(VesperTheme.ink)
            .navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: project.symbol)
                        Text(project.name).lineLimit(1)
                    }.chatNavigationFont(16, weight: .semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if tab == "Chats" {
                    HStack(spacing: 10) {
                        Button(action: newChat) { Image(systemName: "plus").font(.system(size: 20)).frame(width: 36, height: 44) }
                            .accessibilityLabel("New chat in " + project.name).disabled(!canSend)
                        TextField("Message " + project.name, text: $draft, axis: .vertical)
                            .chatNavigationFont(14, weight: .regular).lineLimit(1...4)
                            .submitLabel(.send).onSubmit { if canSend { send() } }
                        Button(action: send) {
                            Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(VesperTheme.palette == .black ? Color.black : Color.white).frame(width: 34, height: 34)
                                .background(VesperTheme.ink, in: Circle())
                        }.accessibilityLabel("Send in new project chat")
                            .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                    }.buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 5)
                        .vesperGlass(in: RoundedRectangle(cornerRadius: 28), interactive: true)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                }
            }
    }
}

private struct SpaceNavigationTitle: ViewModifier {
    let embedded: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.navigationTitle("Space").navigationBarTitleDisplayMode(.inline) }
    }
}
