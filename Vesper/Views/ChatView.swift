import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

private struct ChatScrollUpdate: Equatable {
    let conversationID: String
    let messageCount: Int
    let lastMessageID: String?
    let lastContent: String
    let localMessageID: String?
    let viewportHeight: CGFloat
    let followsLatest: Bool
}

private struct AttachmentRowAlignment: ViewModifier {
    let single: Bool
    let user: Bool
    func body(content: Content) -> some View {
        if single { content.containerRelativeFrame(.horizontal, alignment: user ? .trailing : .leading) }
        else { content }
    }
}

private struct ChatAttachmentPreviewButton<Label: View>: View {
    let url: URL
    let name: String
    @ViewBuilder var label: () -> Label
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { label() }.buttonStyle(.plain)
            .sheet(isPresented: $showing) { ChatAttachmentPreview(url: url, name: name) }
    }
}

private struct ChatAttachmentPreview: View {
    let url: URL
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var localURL: URL?
    @State private var text: String?
    @State private var error = ""
    @State private var directory: URL?
    var body: some View {
        NavigationStack {
            Group {
                if let text {
                    ScrollView { Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else if let localURL { AttachmentQuickLook(url: localURL) }
                else if !error.isEmpty { VStack(spacing: 16) { Text(error); Button("Retry") { Task { await load() } } }.padding() }
                else { ProgressView("Loading preview…") }
            }
            .navigationTitle(name.isEmpty ? "File preview" : name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { if let localURL { ShareLink(item: localURL) { Label("Save or share", systemImage: "square.and.arrow.up") } } }
            }
            .task { await load() }
            .onDisappear { if let directory { try? FileManager.default.removeItem(at: directory) } }
        }
    }
    @MainActor private func load() async {
        error = ""
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            try Task.checkCancellation()
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            let filename = (name as NSString).lastPathComponent
            let target = folder.appendingPathComponent(filename.isEmpty || filename == "." || filename == ".." ? "attachment" : filename)
            try FileManager.default.moveItem(at: temporary, to: target)
            if ["md", "markdown", "txt", "csv", "json", "log"].contains(target.pathExtension.lowercased()) {
                let size = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                if size <= 2_000_000 { text = try? String(contentsOf: target, encoding: .utf8) }
            }
            localURL = target
        } catch is CancellationError { }
        catch { self.error = "Could not preview this file: " + error.localizedDescription }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { context.coordinator.url = url; controller.reloadData() }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

// Text edits must not invalidate the chat timeline. Only the field and its
// send button observe this object; attachments still notify ChatView.
final class ChatTypedDraft: ObservableObject {
    @Published var text = ""
}

private struct ChatDraftField: View {
    @ObservedObject var draft: ChatTypedDraft
    @FocusState.Binding var focused: Bool
    let listening: Bool

    var body: some View {
        TextField(listening ? "Listening…" : "Write to Rowan…", text: $draft.text, axis: .vertical)
            .lineLimit(1...5).focused($focused).font(.system(size: 16))
    }
}

private struct ChatSendButton: View {
    @ObservedObject var draft: ChatTypedDraft
    let hasAttachment: Bool
    let blocked: Bool
    let send: () -> Void

    var body: some View {
        Button(action: send) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40)
        }
        .disabled((draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachment) || blocked)
        .accessibilityLabel("Send")
    }
}

final class ChatComposer: ObservableObject {
    let typedDraft = ChatTypedDraft()
    var draft: String {
        get { typedDraft.text }
        set { typedDraft.text = newValue }
    }
    @Published var images: [Data] = []
    @Published var files: [ChatFile] = []
    @Published var pendingMusic: JSONValue?
    private struct Draft { var text: String; var images: [Data]; var files: [ChatFile]; var music: JSONValue? }
    private var saved: [String: Draft] = [:]
    func switchConversation(from: String, to: String) {
        guard from != to else { return }
        saved[from] = Draft(text: draft, images: images, files: files, music: pendingMusic)
        let next = saved[to]; draft = next?.text ?? ""; images = next?.images ?? []; files = next?.files ?? []; pendingMusic = next?.music
    }
}

struct ChatView: View {
    var onMenu: () -> Void = {}
    var restoreLatest = true
    var native = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @StateObject private var speech = SpeechInput()
    @StateObject private var location = ChatLocation()
    @State private var speechBase = ""
    @State private var avatarRole = "user"
    @State private var avatarPicker = false
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var savingAvatar = false
    @EnvironmentObject private var draftStore: ChatComposer
    private var draft: String { get { draftStore.draft } nonmutating set { draftStore.draft = newValue } }
    @State private var history = false
    @State private var historyTab = 0
    @State private var query = ""
    @State private var renaming: JSONValue?
    @State private var renameText = ""
    @State private var removingConversation: JSONValue?
    @State private var modelPicker = false
    @State private var drawer = false
    @State private var photoPicker = false
    @State private var cameraPicker = false
    @State private var call = false
    @State private var filePicker = false
    @State private var musicPicker = false
    @State private var stickerPicker = false
    private var pendingMusic: JSONValue? { get { draftStore.pendingMusic } nonmutating set { draftStore.pendingMusic = newValue } }
    @State private var nearBottom = true
    @State private var followsLatest = true
    @State private var positionedConversationID: String?
    @State private var observedLocalMessageID: String?
    @State private var draggingHistory = false
    @State private var viewportHeight: CGFloat = 0
    @State private var locationPicker = false
    @State private var confirmNew = false
    @State private var deleting: JSONValue?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    private var images: [Data] { get { draftStore.images } nonmutating set { draftStore.images = newValue } }
    private var files: [ChatFile] { get { draftStore.files } nonmutating set { draftStore.files = newValue } }
    @State private var loadingPhotos = false
    @FocusState private var focused: Bool
    private var chatContent: some View {
        VStack(spacing: 0) {
            header.zIndex(1)
            if !chat.memoryStatus.isEmpty { Text(chat.memoryStatus).font(.caption2).foregroundStyle(VesperTheme.muted).padding(.horizontal) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if chat.hasOlderMessages { Button(chat.loadingOlder ? "Loading…" : "Load earlier messages") { followsLatest = false; Task { await chat.loadOlder() } }.disabled(chat.loadingOlder) }
                        if chat.messages.isEmpty { Text("A little space for us.").font(VesperTheme.title(30)).foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity).padding(.top, 70) }
                        ForEach(ChatPresentation.displayRows(chat.messages)) { row in
                            if let message = row.messages.first {
                                if row.activity { AssistantMessageHeading(message: message, activities: row.activities) }
                                else { messageRow(message, activities: row.activities).id(message.id) }
                            }
                        }
                        if chat.busy {
                            AssistantMessageHeading(message: .object(["status": .string(chat.busy ? "streaming" : "delivered"), "metadata": .object(["thoughtSummary": .string(chat.thinkingSummary)])]), liveEvents: chat.events)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                    .background(GeometryReader { geometry in Color.clear.preference(key: ChatBottomPosition.self, value: geometry.frame(in: .named("chat-scroll")).maxY) })
                    .opacity(positionedConversationID == chat.conversationID || chat.messages.isEmpty ? 1 : 0)
                }.scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(followsLatest ? .bottom : nil)
                .coordinateSpace(name: "chat-scroll")
                .background(GeometryReader { geometry in Color.clear.onAppear { viewportHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, value in viewportHeight = value } })
                .onPreferenceChange(ChatBottomPosition.self) { bottom in
                    guard let bottom, viewportHeight > 0 else { return }
                    nearBottom = bottom <= viewportHeight + 2
                    if draggingHistory || nearBottom { followsLatest = nearBottom }
                 }
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        draggingHistory = true
                        followsLatest = false
                        positionedConversationID = chat.conversationID
                    }
                    .onEnded { _ in
                        draggingHistory = false
                        followsLatest = nearBottom
                    })
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        composer
                        if drawer { attachmentDrawer.transition(.move(edge: .bottom).combined(with: .opacity)) }
                    }
                    .overlay(alignment: .top) {
                        if !nearBottom && !chat.messages.isEmpty {
                            Button {
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(VesperTheme.ink)
                                    .frame(width: 40, height: 40)
                                    .background(.regularMaterial, in: Circle())
                                    .overlay(Circle().stroke(VesperTheme.muted.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain).accessibilityLabel("回到最新消息")
                            .offset(y: -48)
                        }
                    }
                }
                .onChange(of: chat.jumpMessageID) { _, id in
                    guard let id else { return }; followsLatest = false
                    Task { await Task.yield(); withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .task(id: scrollUpdate) { await positionLatest(using: proxy) }
                .onAppear {
                    positionedConversationID = nil
                    observedLocalMessageID = chat.latestLocalMessageID
                    followsLatest = true
                }
                .onChange(of: chat.conversationID) { _, _ in
                    positionedConversationID = nil
                    observedLocalMessageID = chat.latestLocalMessageID
                    followsLatest = true
                    nearBottom = true
                }
            }
        }
    }
    private var scrollUpdate: ChatScrollUpdate {
        ChatScrollUpdate(conversationID: chat.conversationID,
                         messageCount: chat.messages.count,
                         lastMessageID: chat.messages.last?.id,
                         lastContent: chat.messages.last?["content"].string ?? "",
                         localMessageID: chat.latestLocalMessageID,
                         viewportHeight: viewportHeight,
                         followsLatest: followsLatest)
    }
    @MainActor private func positionLatest(using proxy: ScrollViewProxy) async {
        let conversationID = chat.conversationID
        if let target = chat.jumpMessageID, chat.messages.contains(where: { $0.id == target }) {
            followsLatest = false; positionedConversationID = conversationID
            await Task.yield(); proxy.scrollTo(target, anchor: .center); return
        }
        let firstPosition = positionedConversationID != conversationID
        let sentLocally = observedLocalMessageID != chat.latestLocalMessageID
        guard firstPosition || sentLocally || followsLatest else { return }
        guard !draggingHistory, !chat.messages.isEmpty, viewportHeight > 0 else { return }
        // History and thread/resume arrive asynchronously. Scroll after their
        // rows enter the layout, independently of the measured bottom state.
        await Task.yield()
        guard !Task.isCancelled, chat.conversationID == conversationID, !draggingHistory else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
        await Task.yield()
        guard !Task.isCancelled, chat.conversationID == conversationID, !draggingHistory else { return }
        positionedConversationID = conversationID
        observedLocalMessageID = chat.latestLocalMessageID
        followsLatest = true
    }
    private var photoContent: some View {
        chatContent
        .task { chat.configure(store); if restoreLatest { await chat.loadConversations(); if chat.messages.isEmpty && !chat.conversations.contains(where: { $0.id == chat.conversationID }) { await chat.openMainRoom() } } }
        .onChange(of: focused) { _, value in if value { drawer = false } }
        .onChange(of: speech.text) { _, text in draft = speechBase + (speechBase.isEmpty || text.isEmpty ? "" : " ") + text }
        .onChange(of: voiceRecorder.error) { _, error in if let error { chat.error = error } }
        .onChange(of: speech.error) { _, error in if let error { chat.error = error } }
        .onDisappear { speech.stop(); voiceRecorder.cancel() }
        .photosPicker(isPresented: $avatarPicker, selection: $avatarPhoto, matching: .images)
        .onChange(of: avatarPhoto) { _, pick in
            guard let pick else { return }
            let role = avatarRole
            savingAvatar = true
            Task {
                defer { savingAvatar = false; avatarPhoto = nil }
                do {
                    guard let data = try await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw ServiceError(message: "Could not read this photo.") }
                    let scale = min(1, 640 / max(image.size.width, image.size.height))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw ServiceError(message: "Could not prepare this photo.") }
                    let saved = await store.mutate("profile", verifySavedValue: true) { current in
                        var profile = current
                        profile["\(role)Avatar"] = .string("data:image/jpeg;base64," + jpeg.base64EncodedString())
                        return profile
                    }
                    if !saved { chat.error = store.error ?? "Could not save this avatar." }
                } catch { chat.error = error.localizedDescription }
            }
        }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhotos, maxSelectionCount: max(1, 5 - images.count), matching: .images)
        .onChange(of: selectedPhotos) { _, picks in
            guard !picks.isEmpty else { return }; loadingPhotos = true
            Task {
                for pick in picks {
                    do {
                        guard let bytes = try await pick.loadTransferable(type: Data.self), let image = UIImage(data: bytes), let jpeg = image.jpegData(compressionQuality: 0.8), jpeg.count <= 16 * 1024 * 1024 else { throw ServiceError(message: "Choose a photo under 16 MB.") }
                        if images.count < 5 { images.append(jpeg) }
                    } catch { chat.error = error.localizedDescription }
                }
                selectedPhotos = []; loadingPhotos = false
            }
        }
    }
    private var attachmentContent: some View {
        photoContent
        .fullScreenCover(isPresented: $cameraPicker) { ChatCameraPicker { data in if let data, images.count < 5 { images.append(data) }; cameraPicker = false }.ignoresSafeArea() }
        .fullScreenCover(isPresented: $call) { NativeCallView() }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    guard files.count < 5 else { break }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 32 * 1024 * 1024 else { throw ServiceError(message: "Choose files under 32 MB.") }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 32 * 1024 * 1024 else { throw ServiceError(message: "Choose files under 32 MB.") }
                    files.append(ChatFile(name: url.lastPathComponent, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data))
                }
            } catch { chat.error = error.localizedDescription }
        }
        .sheet(isPresented: $locationPicker) { locationSheet }
        .sheet(isPresented: $musicPicker) { musicSheet }
        .sheet(isPresented: $stickerPicker) { NavigationStack { StickerLibraryView { sticker in
            Task { if await chat.send("", sticker: sticker) { stickerPicker = false; drawer = false } }
        } } }
        .sheet(isPresented: $history) { historySheet }
        .confirmationDialog("Start a new chat and clear this draft?", isPresented: $confirmNew) { Button("New chat", role: .destructive) { newChat() } }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let message = deleting { Task { await chat.deleteMessage(message) } }; deleting = nil }
        }
    }
    private var modelSheet: some View {
            NavigationStack {
                List {
                    Button { chat.selectModel("") } label: {
                        HStack { Text("Default model"); Spacer(); if chat.model.isEmpty { Image(systemName: "checkmark") } }
                    }
                    ForEach(chat.models) { model in
                        Button { chat.selectModel(model["model"].string) } label: {
                            HStack {
                                Text(model["displayName"].string.isEmpty ? model["model"].string : model["displayName"].string)
                                Spacer()
                                if chat.model == model["model"].string { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Section("Reasoning effort") {
                        if chat.model.isEmpty {
                            Text("Choose a model to see its supported effort levels.").font(.caption).foregroundStyle(VesperTheme.muted)
                        } else {
                            Picker("Strength", selection: $chat.effort) {
                                Text("Default").tag("")
                                ForEach(chat.supportedEfforts, id: \.self) { value in
                                    Text(value == "xhigh" ? "Extra high" : value.capitalized).tag(value)
                                }
                            }.pickerStyle(.inline)
                            if chat.supportedEfforts.isEmpty { Text("This model does not offer adjustable reasoning effort.").font(.caption) }
                        }
                    }
                    if chat.loadingModels { ProgressView("Loading models…") }
                    if let error = chat.modelError {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await chat.loadModels() } }.disabled(chat.loadingModels)
                    }
                }.navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { modelPicker = false } } }
                    .task { chat.configure(store); await chat.loadModels() }
            }.presentationDetents([.medium, .large])
    }
    var body: some View {
        attachmentContent
        .safeAreaInset(edge: .top) {
            if chat.reconnecting {
                VStack(spacing: 4) {
                    HStack { ProgressView(); Text("Reconnecting…") }
                    Text("\(chat.connectionStage.rawValue) · attempt \(chat.recoveryAttempts)/5").font(.caption2)
                }.font(.caption).padding(8)
            } else if chat.connectionNeedsRetry || chat.unconfirmedSend {
                HStack {
                    Text(chat.connectionNeedsRetry ? (chat.connectionIssue ?? "Chat disconnected. Tap Retry.") : "Send unconfirmed; checking server history avoids duplicates.")
                    Button(chat.connectionNeedsRetry ? "Retry" : "Check status") { chat.retryConnection() }
                }.font(.caption).padding(8)
            }
        }
        .sheet(isPresented: $modelPicker) { modelSheet }
        .sheet(isPresented: Binding(get: { chat.approval != nil }, set: { if !$0 { Task { await chat.resolveApproval(accept: false) } } })) {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text("Review this action").font(.title2)
                    Text(chat.approval?["params"].pretty ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack { Button("Decline", role: .cancel) { Task { await chat.resolveApproval(accept: false) } }; Spacer(); Button("Allow once") { Task { await chat.resolveApproval(accept: true) } }.buttonStyle(.borderedProminent) }
                }.padding() }.navigationTitle("Approval")
            }.interactiveDismissDisabled()
        }
        .alert("Chat", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) { Button("OK") { chat.error = nil } } message: { Text(chat.error ?? "") }
    }
    @Environment(\.dismiss) private var dismissChat
    private var header: some View {
        HStack(spacing: 5) {
            if native { Button { dismissChat() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back to chats") }
            else { Button(action: onMenu) { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar") }
            Spacer()
            Button { avatarRole = "user"; avatarPicker = true } label: { profileAvatar("user", fallbackName: "Vera") }.accessibilityLabel("Change Vera’s avatar").disabled(savingAvatar)
            Button { avatarRole = "agent"; avatarPicker = true } label: { profileAvatar("agent", fallbackName: "Rowan") }.accessibilityLabel("Change Rowan’s avatar").disabled(savingAvatar)
            Spacer()
            AppearancePicker()
        }.font(.system(size: 20)).buttonStyle(ChatHeaderButton()).padding(.horizontal, 12).padding(.vertical, 4)
    }
    private func profileAvatar(_ role: String, fallbackName: String) -> some View {
        let profile = store.document("profile")
        let source = profile["\(role)Avatar"].string
        let name = profile["\(role)Name"].string
        return Group {
            if source.hasPrefix("data:image/"),
               let comma = source.firstIndex(of: ","),
               let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
               let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !source.isEmpty,
                      let url = URL(string: source, relativeTo: URL(string: store.baseURL))?.absoluteURL,
                      url.scheme == "https" {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                    avatarPlaceholder(role)
                }
            } else {
                avatarPlaceholder(role)
            }
        }
        .frame(width: 40, height: 40).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("\(name.isEmpty ? fallbackName : name) avatar")
    }
    private func avatarPlaceholder(_ role: String) -> some View {
        ZStack {
            Circle().fill(VesperTheme.muted.opacity(role == "user" ? 0.12 : 0.25))
            Image(systemName: "person.fill").font(.system(size: 19)).foregroundStyle(VesperTheme.muted)
        }
    }
    private func messageRow(_ message: JSONValue, activities: [JSONValue]) -> some View {
        let user = ChatPresentation.isUser(message)
        return HStack(alignment: .top, spacing: 0) {
            if user { Spacer(minLength: 42) }
            VStack(alignment: user ? .trailing : .leading, spacing: 8) {
                if !user && message["metadata"]["showTurnStatus"] != .bool(false) { AssistantMessageHeading(message: message, activities: activities, liveEvents: !chat.busy && message.id == chat.messages.last(where: { !ChatPresentation.isUser($0) && !ChatPresentation.isActivity($0) })?.id ? chat.events : []) }
                if !message["metadata"]["attachments"].array.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(Array(message["metadata"]["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                        if attachment["type"].string.hasPrefix("audio/") { VoiceMessageBar(attachment: attachment) }
                        else if attachment["type"].string.hasPrefix("image/") { Artwork(url: attachment["url"].string).frame(width: 160, height: 160).clipShape(RoundedRectangle(cornerRadius: 15)) }
                        else if let url = URL(string: attachment["url"].string), url.scheme == "https" { ChatAttachmentPreviewButton(url: url, name: attachment["name"].string) { HStack(spacing: 12) {
                            Image(systemName: "doc.text").font(.title2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attachment["name"].string.isEmpty ? "Download file" : attachment["name"].string).font(.subheadline).lineLimit(2)
                                Text("Tap to open · " + ByteCountFormatter.string(fromByteCount: Int64(max(0, attachment["size"].number)), countStyle: .file)).font(.caption2).foregroundStyle(VesperTheme.muted)
                            }
                            Image(systemName: "arrow.down.to.line").font(.subheadline)
                        }.frame(minWidth: 190, maxWidth: 280, minHeight: 48, alignment: .leading).padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                    } }.modifier(AttachmentRowAlignment(single: message["metadata"]["attachments"].array.count == 1, user: user)) }.defaultScrollAnchor(user ? .trailing : .leading)
                }
                if message["metadata"]["musicCard"] != .null { ChatMusicCard(track: message["metadata"]["musicCard"]) }
                if message["metadata"]["sticker"] != .null { StickerArtwork(sticker: message["metadata"]["sticker"]).frame(width: 150, height: 150) }
                if message["metadata"]["call"] != .null { CallRecordButton(message: message) }
                if message["metadata"]["musicOnly"] != .bool(true) && message["metadata"]["voiceMessage"] != .bool(true) && message["metadata"]["call"] == .null && !message["content"].string.isEmpty && !(message["metadata"]["attachmentOnly"] == .bool(true) && !message["metadata"]["attachments"].array.isEmpty) {
                    Text(message["content"].string).font(.system(size: 15)).lineSpacing(4).multilineTextAlignment(user ? .trailing : .leading).textSelection(.enabled)
                }
                if message["status"].string == "error" { Text("Send not confirmed").font(.caption).foregroundStyle(.red) }
                if message["status"].string != "streaming" && !chat.replyIsStillRunning(message) {
                    HStack(spacing: 12) {
                        if user { Text(ChatPresentation.time(message["createdAt"].string)).font(.caption2) }
                        Button { UIPasteboard.general.string = message["content"].string } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy message")
                        Button { Task { await favorite(message) } } label: { Image(systemName: isFavorite(message) ? "bookmark.fill" : "bookmark") }.accessibilityLabel("Favorite message").disabled(store.saving)
                        Button { Task { await remember(message) } } label: { Image(systemName: "brain") }.accessibilityLabel("Keep in Memory").disabled(chat.busy)
                        Button { deleting = message } label: { Image(systemName: "trash") }.accessibilityLabel("Delete message").disabled(chat.busy)
                    }.font(.system(size: 15)).foregroundStyle(VesperTheme.muted).buttonStyle(.plain).padding(.vertical, 4)
                }
            }.padding(4).background(chat.jumpMessageID == message.id ? VesperTheme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12)).frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 20) }
        }
    }
    private var composer: some View {
        VStack(spacing: 4) {
            if let track = pendingMusic {
                HStack { ChatMusicCard(track: track); Button { pendingMusic = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove music") }
            }
            if voiceRecorder.recording {
                HStack { Image(systemName: "waveform"); Text("Recording"); if let start = voiceRecorder.startedAt { Text(start, style: .timer).monospacedDigit() }; Spacer(); Button("Cancel") { voiceRecorder.cancel() } }.font(.caption)
            }
            if voiceRecorder.processing { HStack { ProgressView(); Text("Preparing voice message…").font(.caption) } }
            if let voice = voiceRecorder.file {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Label("Voice · \(Int(voice.duration ?? 0))s", systemImage: "waveform"); Spacer(); Button("Remove") { voiceRecorder.cancel() } }
                    Text(voice.transcript?.isEmpty == false ? voice.transcript! : "No transcript; audio can still be sent.").font(.caption).lineLimit(3)
                }.font(.subheadline).padding(8)
            }
            if !images.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topTrailing) { Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.disabled(chat.busy) } }
                } } }
            }
            ForEach(files) { file in HStack { Label(file.name, systemImage: "doc").lineLimit(1); Spacer(); Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark") }.disabled(chat.busy) }.font(.caption) }
            ChatDraftField(draft: draftStore.typedDraft, focused: $focused, listening: speech.listening)
            HStack(spacing: 4) {
                Button { focused = false; speech.stop(); withAnimation(.easeOut(duration: 0.2)) { drawer.toggle() } } label: { Image(systemName: drawer ? "xmark" : "plus").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Attachments").disabled(chat.busy)
                Button { focused = false; modelPicker = true } label: { HStack(spacing: 4) { Text((chat.model.isEmpty ? "Default" : chat.model) + (chat.effort.isEmpty ? "" : " · " + chat.effort.capitalized)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12)).frame(maxWidth: 160, minHeight: 40, alignment: .leading) }.disabled(chat.busy)
                Spacer()
                Button { focused = false; drawer = false; player.pause(); Task { if voiceRecorder.recording { await voiceRecorder.stop() } else { await voiceRecorder.start() } } } label: { Image(systemName: voiceRecorder.recording ? "stop.circle.fill" : "mic").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel(voiceRecorder.recording ? "Finish voice message" : "Record voice message").disabled(chat.busy || voiceRecorder.processing || voiceRecorder.file != nil)
                if chat.busy { Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40) } }
                else {
                    ChatSendButton(draft: draftStore.typedDraft,
                                   hasAttachment: !images.isEmpty || !files.isEmpty || voiceRecorder.file != nil || pendingMusic != nil,
                                   blocked: voiceRecorder.recording || voiceRecorder.processing || loadingPhotos || chat.loadingModels,
                                   send: send)
                }
            }
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25)).overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.8))).padding(.horizontal, 12).padding(.vertical, 8)
    }
    private var attachmentDrawer: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 20) {
            drawerItem("Album", "photo") { photoPicker = true }
            drawerItem("Camera", "camera.fill") { if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPicker = true } else { chat.error = "Camera unavailable on this device." } }
            drawerItem("Call", "phone.fill") { openCall() }
            drawerItem("Location", "mappin.circle.fill") { locationPicker = true; location.locate() }
            drawerItem("File", "folder.fill") { filePicker = true }
            drawerItem("Music", "music.note") { musicPicker = true }
            drawerItem("Stickers", "face.smiling") { stickerPicker = true }
        }.padding(20).background(.regularMaterial)
    }
    private func drawerItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { drawer = false; action() } label: { VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 26)).frame(width: 58, height: 58).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 16)); Text(title).font(.system(size: 12)) }.frame(maxWidth: .infinity) }.buttonStyle(.plain).disabled(chat.busy || loadingPhotos || ((title == "Album" || title == "Camera") && images.count >= 5))
    }
    private var locationSheet: some View {
        NavigationStack { VStack(spacing: 20) {
            if location.loading { ProgressView("Finding your location…") }
            if let coordinate = location.coordinate {
                Text("\(coordinate.latitude), \(coordinate.longitude)").font(.caption)
                Button("Add location to message") { draft += (draft.isEmpty ? "" : "\n") + "My location: https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)"; locationPicker = false }
            }
            if let error = location.error { Text(error); Button("Retry") { location.locate() } }
            Text("Your location is shared only when you send the message.").font(.caption).foregroundStyle(.secondary)
        }.padding().navigationTitle("Location").toolbar { Button("Done") { locationPicker = false } } }.presentationDetents([.medium])
    }
    private var musicSheet: some View {
        NavigationStack { List {
            ForEach(store.document("music").array) { track in Button { pendingMusic = .object(Dictionary(uniqueKeysWithValues: ["id", "title", "artist", "album", "cover", "artwork", "url", "neteaseId"].map { ($0, track[$0]) })); musicPicker = false; drawer = false } label: { Label(track["title"].string, systemImage: "music.note") } }
            if store.document("music").array.isEmpty { Text("Add songs in Music first.") }
        }.navigationTitle("Music").toolbar { Button("Done") { musicPicker = false } } }.presentationDetents([.medium, .large])
    }
    private var historySheet: some View {
        NavigationStack {
            VStack {
                Picker("Collection", selection: $historyTab) { Text("Conversations").tag(0); Text("Favorites").tag(1) }.pickerStyle(.segmented).padding(.horizontal)
                List {
                    if historyTab == 0 {
                        NavigationLink { ChatSearchView() { history = false } } label: { Label("Search all messages", systemImage: "magnifyingglass") }
                        Button { Task { await chat.openMainRoom(); history = false } } label: { Label("Main room", systemImage: "house") }.disabled(chat.busy)
                        Button { history = false; if draft.isEmpty && images.isEmpty && files.isEmpty { newChat() } else { confirmNew = true } } label: { Label("New Chat", systemImage: "plus") }.disabled(chat.busy || chat.loadingModels)
                        ForEach(chat.conversations.filter { query.isEmpty || $0["title"].string.localizedCaseInsensitiveContains(query) }) { item in
                            HStack {
                                Button { Task { await chat.open(item); history = false } } label: { VStack(alignment: .leading) { Text(item["title"].string); Text(item["preview"].string).font(.caption).lineLimit(2); Text(ChatPresentation.time(item["updatedAt"].string)).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                                Menu {
                                    Button("Rename") { renameText = item["title"].string; renaming = item }
                                    Button("Delete", role: .destructive) { removingConversation = item }
                                } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                            }.disabled(chat.busy || chat.callActive)
                            .swipeActions { Button("Delete", role: .destructive) { removingConversation = item }; Button("Rename") { renameText = item["title"].string; renaming = item }.tint(.blue) }
                        }
                    } else {
                        ForEach(store.document("favorites").array.filter { query.isEmpty || $0["content"].string.localizedCaseInsensitiveContains(query) }) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(item["content"].string).font(.system(size: 14)).textSelection(.enabled)
                                HStack { Button("Open chat") { Task { await chat.open(.object(["id": item["conversationId"]])); history = false } }.disabled(chat.busy); Spacer(); Button { Task { _ = await store.remove("favorites", id: item.id) } } label: { Image(systemName: "bookmark.slash") }.disabled(store.saving) }
                            }
                        }
                    }
                }.searchable(text: $query)
            }.navigationTitle("Collection").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { history = false } }
            .alert("Rename conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") { if let item = renaming { Task { await chat.renameConversation(item, title: renameText) } }; renaming = nil }
            }
            .confirmationDialog("Delete this conversation from the list?", isPresented: Binding(get: { removingConversation != nil }, set: { if !$0 { removingConversation = nil } }), titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) { if let item = removingConversation { Task { await chat.removeConversation(item) } }; removingConversation = nil }
            } message: { Text("This permanently deletes the conversation and cannot be undone.") }
        }.presentationDetents([.large])
    }
    private func remember(_ message: JSONValue) async {
        do {
            let source = try await store.api.request("/api/memory/messages", method: "POST", body: .object(["conversationId": .string(chat.conversationID), "messageId": .string(message.id), "role": .string(ChatPresentation.isUser(message) ? "user" : "agent"), "content": message["content"], "createdAt": message["createdAt"], "attachments": message["metadata"]["attachments"]]))
            _ = try await store.api.request("/api/memory", method: "POST", body: .object(["action": .string("create_core"), "body": message["content"], "evidenceIds": .array([source["evidenceId"]])]))
            chat.memoryStatus = "Saved to Memory with its original source."
        } catch { chat.error = error.localizedDescription }
    }
    private func isFavorite(_ message: JSONValue) -> Bool { store.document("favorites").array.contains { $0["messageId"].string == message.id } }
    private func favorite(_ message: JSONValue) async {
        if let item = store.document("favorites").array.first(where: { $0["messageId"].string == message.id }) { _ = await store.remove("favorites", id: item.id); return }
        _ = await store.upsert("favorites", item: .object(["id": .string(UUID().uuidString), "folderId": .string("default"), "messageId": .string(message.id), "conversationId": .string(chat.conversationID), "conversationTitle": .string("Conversations"), "content": message["content"], "role": message["role"], "createdAt": message["createdAt"]]))
    }
    private func newChat() { voiceRecorder.cancel(); speech.stop(); Task { if await chat.createConversation() { draft = ""; images = []; files = []; pendingMusic = nil } } }
    private func openCall() { voiceRecorder.cancel(); speech.stop(); focused = false; drawer = false; call = true }
    private func send() {
        speech.stop(); let sending = draft; let outgoing = images; let outgoingFiles = files + (voiceRecorder.file.map { [$0] } ?? []); let music = pendingMusic; drawer = false
        Task { if await chat.send(sending, images: outgoing, files: outgoingFiles, music: music) { if draft == sending { draft = "" }; images = []; files = []; selectedPhotos = []; pendingMusic = nil; voiceRecorder.cancel() } }
    }

}


private struct ChatHeaderButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.frame(width: 36, height: 44).opacity(configuration.isPressed ? 0.5 : 1) }
}

// Keep persisted records intact; classify only their presentation, never by message text.
enum ChatPresentation {
    struct Row: Identifiable {
        let id: String
        let activity: Bool
        var messages: [JSONValue]
        var activities: [JSONValue] = []
    }
    static func isUser(_ message: JSONValue) -> Bool {
        let role = message["role"].string.lowercased()
        return role == "user" || ["userMessage", "userInput"].contains(message["metadata"]["blockType"].string) || ["userMessage", "userInput"].contains(message["type"].string)
    }
    static func isThinking(_ message: JSONValue) -> Bool {
        ["reasoning", "reasoningSummary", "thinking"].contains(message["metadata"]["blockType"].string) || !message["metadata"]["thoughtSummary"].string.isEmpty
    }
    static func isActivity(_ message: JSONValue) -> Bool {
        if isUser(message) { return false }
        if ["system", "tool", "function"].contains(message["role"].string) { return true }
        let block = message["metadata"]["blockType"].string
        return !block.isEmpty && !["agentMessage", "assistantMessage", "outputMessage", "text", "message", "musicCard", "sticker"].contains(block)
    }
    static func rows(_ messages: [JSONValue]) -> [Row] {
        var result: [Row] = []
        for message in messages {
            let activity = isActivity(message)
            if activity, let last = result.last, last.activity, isThinking(last.messages[0]) == isThinking(message) {
                result[result.count - 1].messages.append(message)
            } else { result.append(Row(id: message.id, activity: activity, messages: [message])) }
        }
        return result
    }
    static func isWakeActivity(_ message: JSONValue) -> Bool {
        let meta = message["metadata"]
        let wake = meta["wake"] != .null || !meta["wakeRunId"].string.isEmpty || meta["source"].string == "automation" || message.id.hasPrefix("execution:auto-")
        return wake && isActivity(message)
    }
    static func displayRows(_ input: [JSONValue]) -> [Row] {
        let messages = ChatTranscript.ordered(input).filter { !isWakeActivity($0) }
        let replies = messages.indices.filter { !isUser(messages[$0]) && !isActivity(messages[$0]) }
        var attached: [Int: [JSONValue]] = [:]
        var orphans: [Int] = []
        for index in messages.indices where isActivity(messages[index]) {
            let turn = messages[index]["metadata"]["turnId"].string
            let exact = turn.isEmpty ? nil : replies.first { messages[$0]["metadata"]["turnId"].string == turn }
            // For legacy records without turn IDs, stay within this user's turn.
            let lower = messages.indices.last { $0 < index && isUser(messages[$0]) } ?? -1
            let upper = messages.indices.first { $0 > index && isUser(messages[$0]) } ?? messages.count
            let nearby = replies.filter { $0 > lower && $0 < upper && (turn.isEmpty || messages[$0]["metadata"]["turnId"].string.isEmpty) }
            if let target = exact ?? nearby.first(where: { $0 > index }) ?? nearby.last {
                attached[target, default: []].append(messages[index])
            } else { orphans.append(index) }
        }
        return messages.indices.compactMap { index in
            if isActivity(messages[index]) {
                guard orphans.contains(index) else { return nil }
                return Row(id: messages[index].id, activity: true, messages: [messages[index]], activities: [messages[index]])
            }
            return Row(id: messages[index].id, activity: false, messages: [messages[index]], activities: attached[index] ?? [])
        }
    }
    static func time(_ raw: String, full: Bool = false) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: raw)
        if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: raw) }
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = full ? "M/d HH:mm:ss" : (Calendar.current.isDateInToday(date) ? "HH:mm" : "MMM d, HH:mm")
        return formatter.string(from: date)
    }
}

private struct MiniTerminal: View {
    let execution: JSONValue
    @State private var expanded = false
    @State private var details = false
    private var title: String { execution["title"].string.isEmpty ? "Terminal" : execution["title"].string }
    private var statusColor: Color { ["failed", "error"].contains(execution["status"].string) ? .red : execution["status"].string == "running" ? .yellow : .white.opacity(0.8) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { details = true } label: { Label(title, systemImage: "terminal").lineLimit(1) }
                Spacer()
                Text(execution["status"].string.capitalized).font(.caption2).foregroundStyle(statusColor)
                Button { details = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Expand terminal")
            }
            if expanded { output.frame(maxHeight: 220) }
        }.font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.white.opacity(0.9))
        .padding(12).background(Color(red: 0.12, green: 0.14, blue: 0.18), in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.plain)
        .sheet(isPresented: $details) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ForEach([Color.red, Color.yellow, Color.green], id: \.self) { color in Circle().fill(color).frame(width: 10, height: 10) }
                    Text(title).lineLimit(1); Spacer()
                    Button("Done") { details = false }
                }
                output
            }.padding().font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
            .background(Color(red: 0.12, green: 0.14, blue: 0.18)).presentationDetents([.height(300), .large])
        }
    }
    private var output: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(execution["status"].string.capitalized).foregroundStyle(statusColor)
                    if execution["durationMs"] != .null { Text(String(format: "%.1fs", execution["durationMs"].number / 1000)) }
                }
                if !execution["cwd"].string.isEmpty { Text(execution["cwd"].string) }
                if execution["exitCode"] != .null { Text("Exit \(Int(execution["exitCode"].number))") }
                if !execution["command"].string.isEmpty { Text("$ " + execution["command"].string) }
                ForEach(Array(execution["files"].array.enumerated()), id: \.offset) { _, file in
                    Text(file["path"].string).foregroundStyle(.cyan)
                    code(file["diff"].string.isEmpty ? "No diff returned by the server." : file["diff"].string)
                    if file["truncated"].bool { Text("Saved diff is partial.").foregroundStyle(.yellow) }
                }
                if !execution["output"].string.isEmpty { code(execution["output"].string) }
                if execution["output"].string.isEmpty && execution["files"].array.isEmpty { Text(execution["status"].string == "running" ? "Waiting for result…" : "No detailed output was saved for this call.") }
                if execution["truncated"].bool || execution["filesTruncated"].bool { Text("The saved output is partial.").foregroundStyle(.yellow) }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func code(_ value: String) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(value.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : line.hasPrefix("@@") ? Color.cyan : Color.white.opacity(0.9))
            }
        }
    }
}

private struct AssistantMessageHeading: View {
    let message: JSONValue
    var activities: [JSONValue] = []
    var liveEvents: [String] = []
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Circle().fill(VesperTheme.muted).frame(width: 6, height: 6)
                    let time = ChatPresentation.time(message["createdAt"].string, full: true)
                    if !time.isEmpty { Text(time) } else if message["status"].string != "streaming" { Text("Thinking") }
                    if message["status"].string == "streaming" { Text("Thinking…") }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                }.font(.system(size: 12)).foregroundStyle(VesperTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Date, time and Thinking").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                ForEach(activities.filter { $0["metadata"]["execution"] != .null }) { item in MiniTerminal(execution: item["metadata"]["execution"]) }
                let toolEvents = liveEvents.isEmpty ? message["metadata"]["toolEvents"].array.map { $0.string } : liveEvents
                let toolCards = ToolActivityRecords.cards(toolEvents)
                if !toolCards.isEmpty {
                    Text("Tool calls").font(.caption).foregroundStyle(VesperTheme.muted)
                    ForEach(toolCards) { card in MiniTerminal(execution: card) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thinking summary").font(.caption).foregroundStyle(VesperTheme.muted)
                    if !message["metadata"]["thoughtSummary"].string.isEmpty {
                        Text(message["metadata"]["thoughtSummary"].string).font(.system(size: 13)).textSelection(.enabled)
                    }
                    ForEach(activities.filter { $0["metadata"]["execution"] == .null }) { item in
                        Group {
                            Text(item["metadata"]["thoughtSummary"].string.isEmpty ? item["content"].string : item["metadata"]["thoughtSummary"].string).font(.system(size: 13)).textSelection(.enabled)
                        }
                    }

                    if activities.isEmpty && toolEvents.isEmpty && message["metadata"]["thoughtSummary"].string.isEmpty {
                        Text("No saved details for this message.").font(.caption)
                    }
                }.foregroundStyle(VesperTheme.muted).padding(.vertical, 4)
            }
        }
    }
}

private struct CallRecordButton: View {
    let message: JSONValue
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label(message["content"].string, systemImage: message["metadata"]["call"]["video"] == .bool(true) ? "video" : "phone").padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(message["content"].string).font(.headline)
                        if message["metadata"]["call"]["transcript"].array.isEmpty { Text("No conversation was recorded.").foregroundStyle(.secondary) }
                        ForEach(Array(message["metadata"]["call"]["transcript"].array.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry["speaker"].string + " · " + ChatPresentation.time(entry["at"].string)).font(.caption).foregroundStyle(.secondary)
                                Text(entry["text"].string).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }.navigationTitle("Call transcript").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showing = false } } }
            }
        }
    }
}

private struct ChatBottomPosition: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        // Siblings without a measurement must not overwrite the content position with zero.
        if let next = nextValue() { value = next }
    }
}
