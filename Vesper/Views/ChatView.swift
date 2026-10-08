import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

private struct ChatScrollUpdate: Equatable {
    let visible: Bool
    let conversationID: String
    let messageCount: Int
    let lastMessageID: String?
    let lastContent: String
    let localMessageID: String?
    let jumpMessageID: String?
    let quoteJumpRevision: Int
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


struct ChatIssueSheet: View {
    let issues: [ChatIssue]
    let retry: (ChatIssue.Action) -> Void
    let dismiss: (String) -> Void
    let close: () -> Void
    @AppStorage("vesperPalette") private var palette = "blue"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if issues.isEmpty { Text("没有待处理的问题。") }
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(issue.title).font(.headline)
                            Text(issue.detail).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 16) {
                                if issue.action != .none {
                                    Button(issue.action == .models ? "Reload models" : "Retry") { retry(issue.action) }
                                        .buttonStyle(.borderedProminent).tint(VesperTheme.ink)
                                        .foregroundStyle(palette == "black" ? Color.black : Color.white)
                                }
                                if issue.dismissible {
                                    Button { dismiss(issue.id) } label: {
                                        Text("Dismiss").font(.body.weight(.medium))
                                            .foregroundStyle(VesperTheme.ink)
                                            .padding(.horizontal, 18).frame(minHeight: 44)
                                            .background(VesperTheme.ink.opacity(0.08), in: Capsule())
                                            .vesperMaterial(.thinMaterial, in: Capsule())
                                            .overlay(Capsule().stroke(VesperTheme.ink.opacity(0.18), lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if issue.id != issues.last?.id { Divider() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: close).foregroundStyle(VesperTheme.ink)
                    }
                }
        }.foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink)
            .preferredColorScheme(palette == "black" ? .dark : .light)
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.vesperChatTabSelected) private var chatTabSelected
    @ObservedObject private var inbox = ChatInbox.shared
    @State private var chatVisible = false
    @State private var incomingFrames: [String: CGRect] = [:]
    @State private var scrollFrame = CGRect.zero
    @State private var headerFrame = CGRect.zero
    @State private var headerActionsExpanded = false
    @State private var composerFrame = CGRect.zero

    @MainActor init(onMenu: @escaping () -> Void = {}, restoreLatest: Bool = true, native: Bool = false, inbox: ChatInbox? = nil) {
        self.onMenu = onMenu; self.restoreLatest = restoreLatest; self.native = native
        self.inbox = inbox ?? .shared
    }

    var onMenu: () -> Void = {}
    var restoreLatest = true
    var native = false
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @StateObject private var actionMenu = ChatActionMenu()
    @State private var quoteJumpPart: String?
    @State private var quoteJumpRevision = 0
    @StateObject private var speech = SpeechInput()
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
    @State private var connectionDetails = false
    @State private var terminalVisible = false
    @State private var memoryRecallVisible = false
    @State private var drawer = false
    @State private var photoPicker = false
    @State private var cameraPicker = false
    @State private var filePicker = false
    @State private var musicPicker = false
    @State private var stickerPicker = false
    @State private var attachmentPanelHeight: CGFloat = 220
    private var pendingMusic: JSONValue? { get { draftStore.pendingMusic } nonmutating set { draftStore.pendingMusic = newValue } }
    private var pendingSticker: JSONValue? { get { draftStore.pendingSticker } nonmutating set { draftStore.pendingSticker = newValue } }
    @State private var nearBottom = true
    @State private var followsLatest = true
    @State private var positionedConversationID: String?
    @State private var positionedJumpMessageID: String?
    @State private var observedLocalMessageID: String?
    @State private var draggingHistory = false
    @State private var viewportHeight: CGFloat = 0
    @State private var locationPicker = false
    @State private var confirmNew = false
    @State private var deleting: [JSONValue]?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    private var images: [Data] { get { draftStore.images } nonmutating set { draftStore.images = newValue } }
    private var files: [ChatFile] { get { draftStore.files } nonmutating set { draftStore.files = newValue } }
    @State private var loadingPhotos = false
    @FocusState private var focused: Bool
    private var chatContent: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if chat.hasOlderMessages { Button(chat.loadingOlder ? "Loading…" : "Load earlier messages") { followsLatest = false; Task { await chat.loadOlder() } }.disabled(chat.loadingOlder) }
                        if chat.messages.isEmpty { Text("A little space for us.").font(VesperTheme.title(30)).foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity).padding(.top, 70) }
                        ForEach(chat.presentation.rows) { row in
                            if let message = row.messages.first {
                                if ChatPresentation.isLetterReminder(message) {
                                    Button {
                                        LetterNotificationRoute.shared.letterID = message["metadata"]["letterId"].string
                                    } label: {
                                        Label(message["content"].string, systemImage: "envelope.open")
                                            .font(.system(size: 14, design: .serif)).foregroundStyle(VesperTheme.muted)
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                            .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                    }.buttonStyle(.plain).id(message.id)
                                        .background(incomingReadFrame(row))
                                } else if row.activity && row.activities.allSatisfy({ $0["metadata"]["userInput"] != .null }) { QuestionToolRow(message: message) }
                                else if row.activity { AssistantMessageHeading(message: message, activities: row.activities, liveEvents: message.id == chat.liveHeadingID ? chat.events : [], isLive: message.id == chat.liveHeadingID) }
                                else { messageRow(row).id(row.id).background(incomingReadFrame(row)) }
                            }
                        }
                        if chat.preparingSend {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.mini)
                                Text("Sending…")
                            }.font(.system(size: 12)).foregroundStyle(VesperTheme.muted).frame(height: 44)
                        } else if chat.waitingForReply && chat.liveHeadingID == nil {
                            AssistantMessageHeading(message: .object(["status": .string("streaming"), "metadata": .object(["thoughtSummary": .string(chat.thinkingSummary)])]), liveEvents: chat.events, isLive: true)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.horizontal, 20).padding(.top, 62).padding(.bottom, 14)
                    .background(GeometryReader { geometry in Color.clear.preference(key: ChatBottomPosition.self, value: geometry.frame(in: .named("chat-scroll")).maxY) })
                    .opacity(positionedConversationID == chat.conversationID || chat.messages.isEmpty ? 1 : 0)
                }.scrollDismissesKeyboard(.interactively)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    scrollFrame = frame; markDisplayedMessages()
                }
                .onPreferenceChange(ChatIncomingFrames.self) { frames in
                    incomingFrames = frames; markDisplayedMessages()
                }
                .defaultScrollAnchor(followsLatest ? .bottom : nil)
                .coordinateSpace(name: "chat-scroll")
                .background(GeometryReader { geometry in Color.clear.onAppear { viewportHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, value in viewportHeight = value } })
                .onPreferenceChange(ChatBottomPosition.self) { bottom in
                    guard let bottom, viewportHeight > 0 else { return }
                    let isNearBottom = bottom <= viewportHeight + (nearBottom ? 60 : 24)
                    if nearBottom != isNearBottom { nearBottom = isNearBottom }
                    // Never re-enable auto-follow while the finger is scrolling history.
                    if !draggingHistory && isNearBottom && !followsLatest { followsLatest = true }
                 }
                .simultaneousGesture(DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        if !draggingHistory { draggingHistory = true }
                        if followsLatest { followsLatest = false }
                        if positionedConversationID != chat.conversationID { positionedConversationID = chat.conversationID }
                    }
                    .onEnded { _ in
                        draggingHistory = false
                        followsLatest = nearBottom
                    })
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        composer
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                                composerFrame = frame; markDisplayedMessages()
                            }
                        if stickerPicker {
                            StickerLibraryView(compact: true, onBack: { stickerPicker = false; drawer = true }) { sticker in
                                pendingSticker = sticker
                                stickerPicker = false; drawer = false
                            }
                            .frame(height: attachmentPanelHeight).vesperMaterial(.regularMaterial)
                        } else if drawer {
                            attachmentDrawer
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { attachmentPanelHeight = $0 }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .top) {
                        if !nearBottom && !chat.messages.isEmpty {
                            Button {
                                chat.jumpMessageID = nil
                                followsLatest = true
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            } label: {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(VesperTheme.ink)
                                    .frame(width: 40, height: 40)
                                    .vesperMaterial(.regularMaterial, in: Circle())
                                    .overlay(Circle().stroke(VesperTheme.muted.opacity(0.3), lineWidth: 1))
                            }
                            .buttonStyle(.plain).accessibilityLabel("回到最新消息")
                            .offset(y: -48)
                        }
                    }
                }
                .task(id: scrollUpdate) { await positionLatest(using: proxy) }
                .onAppear {
                    positionedConversationID = nil
                    positionedJumpMessageID = nil
                    observedLocalMessageID = chat.latestLocalMessageID
                    followsLatest = true
                }
                .onChange(of: chat.conversationID) { _, _ in
                    positionedConversationID = nil
                    positionedJumpMessageID = nil
                    observedLocalMessageID = chat.latestLocalMessageID
                    followsLatest = true
                    nearBottom = true
                }
            }
            if headerActionsExpanded {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { headerActionsExpanded = false }
                    .accessibilityLabel("收起聊天选项")
                    .accessibilityAddTraits(.isButton)
            }
            // Only the controls intercept touches; the gaps reveal the transcript.
            header.zIndex(1)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    headerFrame = frame; markDisplayedMessages()
                }
        }
    }
    private var scrollUpdate: ChatScrollUpdate {
        ChatScrollUpdate(visible: chatVisible && chatTabSelected,
                         conversationID: chat.conversationID,
                         messageCount: chat.messages.count,
                         lastMessageID: chat.messages.last?.id,
                         lastContent: chat.messages.last?["content"].string ?? "",
                         localMessageID: chat.latestLocalMessageID,
                         jumpMessageID: chat.jumpMessageID,
                         quoteJumpRevision: quoteJumpRevision,
                         viewportHeight: viewportHeight,
                         followsLatest: followsLatest)
    }
    @MainActor private func positionLatest(using proxy: ScrollViewProxy) async {
        guard chatVisible, chatTabSelected else { return }
        let conversationID = chat.conversationID
        let sentLocally = observedLocalMessageID != chat.latestLocalMessageID
        if sentLocally { chat.jumpMessageID = nil }
        if let target = chat.jumpMessageID {
            guard positionedJumpMessageID != target,
                  chat.messages.contains(where: { $0.id == target }), viewportHeight > 0 else { return }
            followsLatest = false
            await Task.yield()
            guard !Task.isCancelled, chat.conversationID == conversationID,
                  chat.jumpMessageID == target else { return }
            // Keep the highlight, but consume the scroll request only once.
            proxy.scrollTo(chat.presentation.rowID(forMessageID: target), anchor: .center)
            if let part = quoteJumpPart, part != target, !part.isEmpty {
                // Materialize the original lazy row before targeting its child bubble.
                try? await Task.sleep(for: .milliseconds(120))
                if !Task.isCancelled { proxy.scrollTo(part, anchor: .center) }
                quoteJumpPart = nil
            }
            positionedConversationID = conversationID
            positionedJumpMessageID = target
            return
        }
        positionedJumpMessageID = nil
        let firstPosition = positionedConversationID != conversationID
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
    private func markDisplayedMessages() {
        guard chatVisible, chatTabSelected, phase == .active, positionedConversationID == chat.conversationID else { return }
        var viewport = scrollFrame
        let visibleTop = max(viewport.minY, headerFrame.maxY)
        viewport.size.height = max(0, viewport.maxY - visibleTop)
        viewport.origin.y = visibleTop
        if composerFrame.height > 0 { viewport.size.height = max(0, min(viewport.maxY, composerFrame.minY) - viewport.minY) }
        let ids = ChatReadVisibility.displayedIDs(frames: incomingFrames, viewport: viewport)
        inbox.markDisplayed(conversation: chat.conversationID, messageIDs: ids)
    }
    @ViewBuilder private func incomingReadFrame(_ row: ChatPresentation.Row) -> some View {
        if !row.activity, let message = row.messages.first, !ChatPresentation.isUser(message) {
            GeometryReader { geometry in
                Color.clear.preference(key: ChatIncomingFrames.self, value: Dictionary(
                    row.messages.flatMap { [$0.id, $0["metadata"]["itemId"].string] }.filter { !$0.isEmpty }
                        .map { ($0, geometry.frame(in: .global)) }, uniquingKeysWith: { first, _ in first }))
            }
        }
    }
    private var observedChatContent: some View {
        chatContent
        .environmentObject(actionMenu)
        .overlay { ChatActionOverlay(menu: actionMenu).allowsHitTesting(actionMenu.selection != nil) }
        .onChange(of: chat.conversationID) { _, _ in actionMenu.selection = nil; quoteJumpPart = nil }
        .onAppear { chatVisible = true; markDisplayedMessages() }
        .onDisappear { chatVisible = false }
        .onChange(of: inbox.incoming) { _, _ in markDisplayedMessages() }
        .onChange(of: phase) { _, _ in markDisplayedMessages() }
        .onChange(of: chatTabSelected) { _, _ in markDisplayedMessages() }
        .onChange(of: positionedConversationID) { _, _ in markDisplayedMessages() }
    }
    private var photoContent: some View {
        observedChatContent
        .task { chat.configure(store); if restoreLatest { await chat.loadConversations(); if chat.messages.isEmpty && !chat.conversations.contains(where: { $0.id == chat.conversationID }) { await chat.openMainRoom() } } }
        .onChange(of: focused) { _, value in if value { drawer = false; stickerPicker = false } }
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
        .sheet(isPresented: $history) { historySheet }
        .confirmationDialog("Start a new chat and clear this draft?", isPresented: $confirmNew) { Button("New chat", role: .destructive) { newChat() } }
        .confirmationDialog("Delete this message?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let messages = deleting { Task { await chat.deleteMessages(messages) } }; deleting = nil }
        }
    }
    var body: some View {
        attachmentContent
        .sheet(isPresented: $connectionDetails) {
            ChatIssueSheet(
                issues: chat.issueDetails,
                retry: { action in
                    if action == .models { Task { await chat.loadModels() } }
                    else { chat.retryConnection() }
                },
                dismiss: { chat.dismissIssue($0) },
                close: { connectionDetails = false })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $memoryRecallVisible) { MemoryRecallView(conversationID: chat.conversationID) }
        .sheet(isPresented: $terminalVisible) {
            ChatTerminalView(conversationID: chat.conversationID).environmentObject(chat).presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { chat.approval == nil ? chat.userInputRequests.first : nil }, set: { _ in })) { request in
            ChatQuestionSheet(request: request).environmentObject(chat).id(request.id)
                .presentationDetents([.medium, .large]).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { chat.approval != nil }, set: { if !$0 { Task { await chat.resolveApproval(accept: false) } } })) {
            NavigationStack {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text("Review this action").font(.title2)
                    Text(chat.approval?["params"].pretty ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack { Button("Decline", role: .cancel) { Task { await chat.resolveApproval(accept: false) } }; Spacer(); Button("Allow once") { Task { await chat.resolveApproval(accept: true) } }.buttonStyle(.borderedProminent) }
                }.padding() }.navigationTitle("Approval")
            }.interactiveDismissDisabled()
        }
    }
    @Environment(\.dismiss) private var dismissChat
    private var header: some View {
        // Center the avatar pair on the full header, independently of either side.
        HStack(spacing: 5) {
            Button { avatarRole = "user"; avatarPicker = true } label: { profileAvatar("user", fallbackName: "Vera") }.accessibilityLabel("Change Vera’s avatar").disabled(savingAvatar)
            Button { avatarRole = "agent"; avatarPicker = true } label: { profileAvatar("agent", fallbackName: "Rowan") }.accessibilityLabel("Change Rowan’s avatar").disabled(savingAvatar)
        }.buttonStyle(.plain)
            .frame(maxWidth: .infinity).frame(height: 44)
            .overlay(alignment: .leading) {
                HStack(spacing: 5) {
                    Button {
                        headerActionsExpanded = false
                        if native { dismissChat() } else { onMenu() }
                    } label: {
                        Image(systemName: native ? "chevron.left" : "line.3.horizontal")
                            .font(.system(size: 21, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .vesperGlass(in: Circle(), interactive: true)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(native ? "Back to chats" : "Open sidebar")
                        .accessibilityIdentifier("chat-header-back")
                    if !chat.issueDetails.isEmpty {
                        Button { connectionDetails = true } label: {
                            Group {
                                if chat.issueDetails.allSatisfy(\.progress) { ProgressView().controlSize(.small) }
                                else { Image(systemName: "exclamationmark.circle") }
                            }.frame(width: 28, height: 40)
                        }
                        .accessibilityLabel("查看问题详情")
                        .accessibilityIdentifier("chat-issue-details")
                    }
                }.buttonStyle(ChatHeaderButton())
            }
            .overlay(alignment: .trailing) {
                // Expand above the avatars without participating in their layout.
                ChatHeaderMenu(expanded: $headerActionsExpanded, onMemory: { memoryRecallVisible = true }, onTerminal: { terminalVisible = true })
                    .animation(.easeInOut(duration: 0.2), value: headerActionsExpanded)
            }
            .font(.system(size: 20)).padding(.horizontal, 12).padding(.vertical, 4)
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
    private func messageRow(_ row: ChatPresentation.Row) -> some View {
        let message = row.presentedMessage
        return ChatMessageRow(message: message, mediaMessages: row.messages.filter(ChatPresentation.hasMedia), activities: row.activities,
                       liveEvents: message.id == chat.liveHeadingID || (!chat.busy && message.id == chat.presentation.lastReplyID) ? chat.events : [],
                       isLive: message.id == chat.liveHeadingID,
                       replyIsRunning: chat.replyIsStillRunning(message),
                       favorite: isFavorite(message), saving: store.saving, busy: chat.busy,
                       highlighted: row.messages.contains { $0.id == chat.jumpMessageID },
                       onFavorite: { Task { await favorite(message) } },
                       onRemember: { Task { await remember(row.messages.first { $0.id == row.id } ?? message) } },
                       onDelete: { deleting = row.messages },
                       sourceMessages: row.messages,
                       onPartFavorite: { part in Task { await favorite(part) } },
                       onReply: { part in
                           draftStore.replyTo = ChatBubbles.quote(part, conversationID: chat.conversationID)
                           focused = true
                       },
                       onOpenQuote: { quote in
                           positionedJumpMessageID = nil
                           followsLatest = false
                           quoteJumpRevision += 1
                           chat.jumpMessageID = nil
                           quoteJumpPart = quote["partId"].string
                           Task {
                               let id = quote["messageId"].string
                               await chat.reveal(id)
                               if !chat.messages.contains(where: { $0.id == id }) { chat.error = "原消息已删除或暂时无法加载。" }
                           }
                       })
            .equatable()
    }
    private var composer: some View {
        VStack(spacing: 4) {
            if let reply = draftStore.replyTo {
                HStack {
                    ChatQuotePreview(quote: reply)
                    Button { draftStore.replyTo = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 36, height: 44) }
                        .accessibilityLabel("取消引用")
                }.padding(.bottom, 4)
            }
            if let track = pendingMusic {
                HStack { ChatMusicCard(track: track); Button { pendingMusic = nil } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Remove music") }
            }
            if let sticker = pendingSticker {
                HStack(spacing: 12) {
                    StickerArtwork(sticker: sticker).frame(width: 64, height: 64).allowsHitTesting(false)
                    Text("Add a message, then send").font(.caption).foregroundStyle(VesperTheme.muted)
                    Spacer()
                    Button { pendingSticker = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Remove sticker")
                }.padding(.horizontal, 4)
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
            ChatDraftField(text: draftStore.text, listening: speech.listening, focused: $focused)
            HStack(spacing: 4) {
                Button { focused = false; speech.stop(); withAnimation(.easeOut(duration: 0.2)) { if stickerPicker { stickerPicker = false; drawer = false } else { drawer.toggle() } } } label: { Image(systemName: drawer || stickerPicker ? "xmark" : "plus").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Attachments").disabled(chat.busy)
                Button { focused = false; drawer = false; stickerPicker = false; headerActionsExpanded = false; modelPicker.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(store.activeBackend == .vps ? "VPS" : "MAC").fontWeight(.semibold)
                        Text("· " + (chat.model.isEmpty ? "Default" : chat.model) + (chat.effort.isEmpty ? "" : " · " + chat.effort.capitalized)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: modelPicker ? "chevron.down" : "chevron.up").font(.system(size: 9))
                    }.font(.system(size: 12)).frame(maxWidth: 190, minHeight: 40, alignment: .leading)
                }.disabled(!chat.canSwitchBackend || store.loading)
                    .accessibilityLabel("Backend, model and strength")
                    .accessibilityValue((store.activeBackend == .vps ? "VPS" : "MAC") + ", " + (chat.model.isEmpty ? "Default" : chat.model) + ", " + (chat.effort.isEmpty ? "Default" : chat.effort))
                    .accessibilityIdentifier("chat-model-picker")
                    .popover(isPresented: $modelPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                        ChatModelPopover().environmentObject(store).environmentObject(chat)
                            .presentationCompactAdaptation(.popover)
                            .presentationBackground(.regularMaterial)
                            .task { chat.configure(store); if chat.models.isEmpty { await chat.loadModels() } }
                    }
                Spacer()
                Button { focused = false; drawer = false; stickerPicker = false; store.musicPlayer?.pause(); Task { if voiceRecorder.recording { await voiceRecorder.stop() } else { await voiceRecorder.start(context: chat.messages.filter { !ChatPresentation.isActivity($0) }.suffix(12).map { $0["content"].string } + [draft]) } } } label: { Image(systemName: voiceRecorder.recording ? "stop.circle.fill" : "mic").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel(voiceRecorder.recording ? "Finish voice message" : "Record voice message").disabled(chat.busy || voiceRecorder.processing || voiceRecorder.file != nil)
                if chat.busy { Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40) } }
                else {
                    ChatSendButton(text: draftStore.text,
                                   hasNonTextPayload: !images.isEmpty || !files.isEmpty || voiceRecorder.file != nil || pendingMusic != nil || pendingSticker != nil,
                                   blocked: store.loading || chat.showingCachedHistory || chat.openingMainRoom || voiceRecorder.recording || voiceRecorder.processing || loadingPhotos || chat.loadingModels,
                                   action: send)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.return, modifiers: .command)
                        #endif
                }
            }
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4).vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 25)).overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.8))).padding(.horizontal, 12).padding(.vertical, 8)
    }
    private var attachmentDrawer: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 20) {
            drawerItem("Album", "photo") { photoPicker = true }
            drawerItem("Camera", "camera.fill") { if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPicker = true } else { chat.error = "Camera unavailable on this device." } }
            drawerItem("Call", "phone.fill") { openCall() }
            drawerItem("Location", "mappin.circle.fill") { locationPicker = true }
            drawerItem("File", "folder.fill") { filePicker = true }
            drawerItem("Music", "music.note") { musicPicker = true }
            drawerItem("Stickers", "face.smiling") { stickerPicker = true }
        }.padding(20).vesperMaterial(.regularMaterial)
    }
    private func drawerItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { drawer = false; action() } label: { VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 26)).frame(width: 58, height: 58).background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 16)); Text(title).font(.system(size: 12)) }.frame(maxWidth: .infinity) }.buttonStyle(.plain).disabled(chat.busy || loadingPhotos || ((title == "Album" || title == "Camera") && images.count >= 5))
    }
    private var locationSheet: some View {
        ChatLocationShareSheet { location in
            Task { _ = await chat.send("", location: location, onAccepted: { locationPicker = false; drawer = false }) }
        }
    }
    private var musicSheet: some View {
        ChatMusicSharePicker { track in
            pendingMusic = track
            musicPicker = false; drawer = false
        }
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
            _ = source
            let evidence: JSONValue = .object([
                "conversation_id": .string(chat.conversationID),
                "message_id": .string(message.id),
                "quote": .string(String(message["content"].string.prefix(4000)))
            ])
            let candidate: JSONValue = .object([
                "body": message["content"], "kind": .string("episode"),
                "source": .string("Vesper chat: " + chat.conversationID), "occurred_at": .null,
                "details": .object(["evidence": .array([evidence])])
            ])
            _ = try await store.api.request("/api/memory/candidates", method: "POST", body: .object([
                "action": .string("propose"), "memory": candidate
            ]))
            chat.memoryStatus = "已生成待核对候选；请在相关记忆中确认后入库。"
        } catch { chat.error = error.localizedDescription }
    }
    private func isFavorite(_ message: JSONValue) -> Bool { ChatFavorites.existing(message.id, conversationID: chat.conversationID, in: store) != nil }
    private func favorite(_ message: JSONValue) async {
        if let item = ChatFavorites.existing(message.id, conversationID: chat.conversationID, in: store) { _ = await store.remove("favorites", id: item.id); return }
        let title = chat.conversations.first(where: { $0.id == chat.conversationID })?["title"].string ?? "Chat"
        _ = await ChatFavorites.save(message, conversationID: chat.conversationID, title: title, in: store)
    }
    private func newChat() { voiceRecorder.cancel(); speech.stop(); Task { if await chat.createConversation() { draft = ""; images = []; files = []; pendingMusic = nil; pendingSticker = nil; draftStore.replyTo = nil } } }
    private func openCall() { voiceRecorder.cancel(); speech.stop(); focused = false; drawer = false; stickerPicker = false; NativeCallPresentation.shared.open(initiator: "user") }
    private func send() {
        speech.stop(); let sending = draft; let outgoing = images; let outgoingFiles = files + (voiceRecorder.file.map { [$0] } ?? []); let music = pendingMusic; let sticker = pendingSticker; let quote = draftStore.replyTo; drawer = false; stickerPicker = false
        let conversation = chat.conversationID
        Task {
            var accepted = false
            let sent = await chat.send(sending, images: outgoing, files: outgoingFiles, music: music, sticker: sticker, replyTo: quote, onAccepted: {
                accepted = true
                draft = ""; images = []; files = []; selectedPhotos = []; pendingMusic = nil; pendingSticker = nil; draftStore.replyTo = nil; voiceRecorder.cancel()
            })
            // An ambiguous send remains in the transcript for reconciliation, never auto-resend it.
            if accepted && !sent && !chat.unconfirmedSend && chat.conversationID == conversation && draft.isEmpty && images.isEmpty && files.isEmpty && pendingMusic == nil && pendingSticker == nil {
                draft = sending; images = outgoing; files = outgoingFiles; pendingMusic = music; pendingSticker = sticker; draftStore.replyTo = quote
            }
        }
    }

}


// Value inputs isolate old rows from token, composer and scroll-state updates.
struct ChatMessageRow: View, Equatable {
    let message: JSONValue
    let mediaMessages: [JSONValue]
    let activities: [JSONValue]
    let liveEvents: [String]
    let isLive: Bool
    let replyIsRunning: Bool
    let favorite: Bool
    let saving: Bool
    let busy: Bool
    let highlighted: Bool
    let onFavorite: () -> Void
    let onRemember: () -> Void
    let onDelete: () -> Void
    var sourceMessages: [JSONValue] = []
    var onPartFavorite: (JSONValue) -> Void = { _ in }
    var onReply: (JSONValue) -> Void = { _ in }
    var onOpenQuote: (JSONValue) -> Void = { _ in }
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isLive == rhs.isLive && lhs.message == rhs.message && lhs.mediaMessages == rhs.mediaMessages && lhs.activities == rhs.activities && lhs.liveEvents == rhs.liveEvents &&
        lhs.replyIsRunning == rhs.replyIsRunning && lhs.favorite == rhs.favorite && lhs.sourceMessages == rhs.sourceMessages &&
        lhs.saving == rhs.saving && lhs.busy == rhs.busy && lhs.highlighted == rhs.highlighted
    }
    private var originals: [JSONValue] { sourceMessages.isEmpty ? [message] : sourceMessages }
    var body: some View {
        let user = ChatPresentation.isUser(message)
        HStack(alignment: .top, spacing: 0) {
            if user { Spacer(minLength: 42) }
            VStack(alignment: user ? .trailing : .leading, spacing: 9) {
                if !user { AssistantMessageHeading(message: message, activities: activities, liveEvents: liveEvents, isLive: isLive) }
                ForEach(originals) { original in
                    if ChatBubbles.textParts(original).isEmpty, original["metadata"]["replyTo"] != .null {
                        ChatQuotePreview(quote: original["metadata"]["replyTo"]) { onOpenQuote(original["metadata"]["replyTo"]) }
                    }
                    sharedContent(original, user: user)
                    if original["metadata"]["musicCard"] == .null && original["status"].string != "streaming" {
                        ForEach(ChatMusicShare.links(in: original["content"].string)) { track in
                            let part = ChatBubbles.part(original, key: track.id, text: track["appleMusicURL"].string, metadata: .object(["musicCard": track]))
                            ChatMusicLinkCard(track: track).modifier(ChatLongPress(id: part.id, actions: { actions(part) })).id(part.id)
                        }
                    }
                    if original["metadata"]["call"] != .null {
                        CallRecordButton(message: original, messageActions: { actions(original) })
                    }
                    ForEach(ChatBubbles.textParts(original)) { part in
                        VStack(alignment: .leading, spacing: 8) {
                            if part["metadata"]["replyTo"] != .null {
                                ChatQuotePreview(quote: part["metadata"]["replyTo"]) { onOpenQuote(part["metadata"]["replyTo"]) }
                            }
                            ChatMarkdownText(content: part["content"].string, selectable: false)
                                .font(.system(size: 15)).lineSpacing(4).multilineTextAlignment(.leading)
                        }
                        .modifier(ChatBubbleSurface(user: user))
                        .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                        .id(part.id)
                    }
                }
            }
            .padding(4).background(highlighted ? VesperTheme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 42) }
        }
    }
    private func actions(_ part: JSONValue) -> [ChatMessageAction] {
        guard part["status"].string != "streaming" else { return [] }
        let saved = ChatFavorites.existing(part.id, conversationID: chat.conversationID, in: store) != nil
        return [
            ChatMessageAction(title: "复制", icon: "doc.on.doc", run: { copy(part) }),
            ChatMessageAction(title: saved ? "取消收藏" : "收藏", icon: saved ? "bookmark.fill" : "bookmark", run: { onPartFavorite(part) }),
            ChatMessageAction(title: "引用", icon: "arrowshape.turn.up.left", run: { onReply(part) })
        ]
    }
    private func copy(_ part: JSONValue) {
        let attachment = part["metadata"]["attachments"].array.first ?? .null
        if attachment["type"].string.hasPrefix("image/"), let url = URL(string: attachment["url"].string), url.scheme == "https" {
            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                    UIPasteboard.general.image = image
                } catch { chat.error = "图片复制失败：" + error.localizedDescription }
            }
        } else if attachment != .null, let url = URL(string: attachment["url"].string) { UIPasteboard.general.url = url }
        else { UIPasteboard.general.string = part["content"].string }
    }
    @ViewBuilder private func sharedContent(_ item: JSONValue, user: Bool) -> some View {
        let attachments = item["metadata"]["attachments"].array
        let photoIndices = attachments.indices.filter { attachments[$0]["type"].string.hasPrefix("image/") }
        ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
            let label = attachment["transcript"].string.isEmpty ? attachment["name"].string : attachment["transcript"].string
            let part = ChatBubbles.part(item, key: "attachment-\(index)", text: label.isEmpty ? "附件" : label,
                                       metadata: .object(["attachments": .array([attachment])]))
            Group {
                if attachment["type"].string.hasPrefix("image/") {
                    if index == photoIndices.first {
                        let photos = photoIndices.map { attachments[$0] }
                        let album = ChatBubbles.part(item, key: "attachment-\(index)", text: photos.count > 1 ? "\(photos.count) Photos" : label,
                                                    metadata: .object(["attachments": .array(photos)]))
                        ChatPhotoStack(photos: photos, alignment: user ? .trailing : .leading)
                            .modifier(ChatLongPress(id: part.id, actions: { actions(album) }))
                            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
                    }
                } else if attachment["type"].string.hasPrefix("audio/") {
                    VoiceMessageBar(attachment: attachment, alignment: user ? .trailing : .leading, messageID: part.id, messageActions: { actions(part) }, onTranscript: { text in Task { await chat.saveVoiceTranscript(messageID: item.id, attachmentIndex: index, text: text) } },
                                    onTranslation: { source, text in Task { await chat.saveVoiceTranslation(messageID: item.id, attachmentIndex: index, source: source, text: text) } })
                } else if let url = URL(string: attachment["url"].string), url.scheme == "https" {
                    ChatAttachmentPreviewButton(url: url, name: attachment["name"].string) { ChatFileCard(attachment: attachment) }
                        .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                }
            }.id(part.id)
        }
        ForEach(["locationCard", "musicCard", "sticker"], id: \.self) { key in
            if item["metadata"][key] != .null {
                let media = item["metadata"][key]
                let label = key == "sticker" ? media["name"].string : (key == "musicCard" ? media["title"].string : media["name"].string)
                let part = ChatBubbles.part(item, key: key, text: label.isEmpty ? key : label, metadata: .object([key: media]))
                Group {
                    if key == "locationCard" { ChatLocationCard(location: media) }
                    if key == "musicCard" { ChatMusicCard(track: ChatMusicShare.normalized(media)) }
                    if key == "sticker" { StickerArtwork(sticker: media).frame(width: 150, height: 150) }
                }.modifier(ChatLongPress(id: part.id, actions: { actions(part) })).id(part.id)
            }
        }
    }
}

struct ChatHeaderMenu: View {
    @Binding var expanded: Bool
    let onMemory: () -> Void
    let onTerminal: () -> Void
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    var body: some View {
        ZStack(alignment: .trailing) {
            if expanded {
                HStack(spacing: 8) {
                    actionIcon("相关记忆", symbol: "brain", action: onMemory)
                    actionIcon("终端", symbol: "terminal", action: onTerminal)
                    if VesperLayout.usesSidebar {
                        MacAppearanceButton().frame(width: 44, height: 44)
                    } else {
                    actionIcon(navigationStyle == "native" ? "切换到 Vesper" : "切换到 Apple Native",
                               symbol: navigationStyle == "native" ? "sidebar.left" : "rectangle.bottomthird.inset.filled") {
                        navigationStyle = navigationStyle == "native" ? "vesper" : "native"
                    }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
            } else {
                Button { expanded = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("聊天更多选项")
                    .accessibilityIdentifier("chat-header-more")
                    .transition(.opacity)
            }
        }
        .frame(width: expanded ? 148 : 44, height: 44, alignment: .trailing)
        .foregroundStyle(VesperTheme.ink)
        .vesperGlass(in: Capsule(), interactive: true)
        .accessibilityAction(.escape) { expanded = false }
    }
    private func actionIcon(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button { expanded = false; action() } label: {
            Image(systemName: symbol).font(.system(size: 21))
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

private struct ChatHeaderButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.frame(width: 36, height: 44).opacity(configuration.isPressed ? 0.5 : 1) }
}

// Keep persisted records intact; classify only their presentation, never by message text.
// Retained by ChatSession until the message array changes. Scroll geometry,
// playback ticks and composer state must not re-sort/re-group the transcript.
final class ChatPresentationSnapshot {
    let rows: [ChatPresentation.Row]
    let lastReplyID: String?
    func rowID(forMessageID id: String) -> String {
        rows.first { $0.messages.contains { $0.id == id } }?.id ?? id
    }
    init(_ messages: [JSONValue]) {
        rows = ChatPresentation.displayRows(messages)
        lastReplyID = rows.last { !$0.activity && !$0.messages.contains(where: ChatPresentation.isUser) && !$0.messages.contains(where: ChatPresentation.isLetterReminder) }?.id
    }
}

enum ChatPresentation {
    struct Row: Identifiable {
        let id: String
        let activity: Bool
        var messages: [JSONValue]
        var activities: [JSONValue] = []
        var presentedMessage: JSONValue {
            var primary = messages.first { $0.id == id } ?? .null
            guard messages.count > 1 else { return primary }
            // One timestamp for the whole reply, including media delivered before its text.
            if let first = messages.first { primary["createdAt"] = first["createdAt"] }
            if messages.contains(where: { $0["status"].string == "streaming" }) { primary["status"] = .string("streaming") }
            primary["content"] = .string(messages.map(ChatPresentation.caption).filter { !$0.isEmpty }.joined(separator: "\n\n"))
            for flag in ["attachmentOnly", "musicOnly", "locationOnly"] { primary["metadata"][flag] = .bool(false) }
            // A display snapshot; original records stay in messages for memory and deletion.
            primary["metadata"]["sharedMedia"] = .array(messages.filter(ChatPresentation.hasMedia))
            primary["metadata"]["attachments"] = .array(messages.flatMap { $0["metadata"]["attachments"].array })
            let summaries = messages.map { $0["metadata"]["thoughtSummary"].string }.filter { !$0.isEmpty }
            if let latest = summaries.last { primary["metadata"]["thoughtSummary"] = .string(latest) }
            let events = messages.flatMap { $0["metadata"]["toolEvents"].array }
            if !events.isEmpty { primary["metadata"]["toolEvents"] = .array(events.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }) }
            return primary
        }
    }
    static func hasMedia(_ message: JSONValue) -> Bool {
        let meta = message["metadata"]
        return !meta["attachments"].array.isEmpty || ["sticker", "musicCard", "locationCard"].contains { meta[$0] != .null }
    }
    private static func caption(_ message: JSONValue) -> String {
        let meta = message["metadata"]
        if ["attachmentOnly", "musicOnly", "locationOnly", "voiceMessage"].contains(where: { meta[$0] == .bool(true) }) || meta["call"] != .null { return "" }
        return message["content"].string
    }
    private static func canCombine(_ row: Row, with next: Row) -> Bool {
        let all = row.messages + next.messages
        guard !row.activity, !next.activity, !(row.activities + next.activities).contains(where: { $0["metadata"]["userInput"] != .null }),
              let first = all.first(where: { !$0["metadata"]["turnId"].string.isEmpty }) else { return false }
        let turn = first["metadata"]["turnId"].string, thread = first["metadata"]["threadId"].string
        guard !turn.isEmpty, !thread.isEmpty else { return false }
        return all.allSatisfy {
            let meta = $0["metadata"]
            // Older native voice records carry the thread in their ID but lack turn metadata.
            // Only attach these adjacent records inside the same uninterrupted reply.
            let legacyVoice = meta["voiceMessage"] == .bool(true) && meta["turnId"].string.isEmpty
                && meta["threadId"].string.isEmpty && $0.id.hasPrefix("voice:" + thread + ":")
            let legacyCall: Bool = {
                guard meta["call"] != .null, meta["call"]["initiator"].string == "agent",
                      meta["turnId"].string.isEmpty, meta["threadId"].string.isEmpty,
                      let started = UserHistoryRecovery.parsedTime(meta["call"]["startedAt"].string),
                      let reply = UserHistoryRecovery.parsedTime(first["createdAt"].string) else { return false }
                // Compatibility for old, adjacent call cards. New records carry exact turn IDs.
                return abs(started.timeIntervalSince(reply)) <= 120
            }()
            return !isUser($0) && !isActivity($0) && !isLetterReminder($0) && !ChatTranscript.isWake($0)
                && meta["userInput"] == .null
                && (legacyVoice || legacyCall || (meta["turnId"].string == turn && meta["threadId"].string == thread))
                && $0["conversationId"].string == first["conversationId"].string
        }
    }
    private struct TurnKey: Hashable {
        let conversation: String
        let thread: String
        let turn: String
    }
    private static func turnKey(_ message: JSONValue) -> TurnKey? {
        let meta = message["metadata"]
        guard !meta["turnId"].string.isEmpty else { return nil }
        return TurnKey(conversation: message["conversationId"].string,
                       thread: meta["threadId"].string, turn: meta["turnId"].string)
    }
    private static func canCombineActivities(_ first: Row, _ second: Row) -> Bool {
        guard first.activity, second.activity, let key = first.messages.first.flatMap(turnKey) else { return false }
        return (first.messages + second.messages).allSatisfy {
            turnKey($0) == key && $0["metadata"]["userInput"] == .null && !ChatTranscript.isWake($0)
        }
    }
    private static func combinedMediaRows(_ rows: [Row]) -> [Row] {
        var result: [Row] = []
        for row in rows {
            if let last = result.last, canCombineActivities(last, row) {
                result[result.count - 1] = Row(id: last.id, activity: true,
                    messages: last.messages + row.messages, activities: last.activities + row.activities)
            } else if let last = result.last, canCombine(last, with: row) {
                let messages = last.messages + row.messages
                let primary = messages.first { !hasMedia($0) } ?? messages[0]
                result[result.count - 1] = Row(id: primary.id, activity: false, messages: messages, activities: last.activities + row.activities)
            } else { result.append(row) }
        }
        return result
    }
    static func liveHeadingID(_ rows: [Row], turnID: String) -> String? {
        rows.last { row in
            row.messages.contains { message in
                !isUser(message) && !isLetterReminder(message)
                    && message["metadata"]["turnId"].string == turnID
            }
        }?.id
    }
    static func isUser(_ message: JSONValue) -> Bool {
        let role = message["role"].string.lowercased()
        return role == "user" || ["userMessage", "userInput"].contains(message["metadata"]["blockType"].string) || ["userMessage", "userInput"].contains(message["type"].string)
    }
    static func isThinking(_ message: JSONValue) -> Bool {
        ["reasoning", "reasoningSummary", "thinking"].contains(message["metadata"]["blockType"].string) || !message["metadata"]["thoughtSummary"].string.isEmpty
    }
    static func isLetterReminder(_ message: JSONValue) -> Bool {
        message["role"].string == "system" && message["metadata"]["blockType"].string == "letterReminder" && !message["metadata"]["letterId"].string.isEmpty
    }
    static func isActivity(_ message: JSONValue) -> Bool {
        if isLetterReminder(message) { return false }
        if isUser(message) { return false }
        if message["metadata"]["phase"].string == "commentary" { return true }
        if ["system", "tool", "function"].contains(message["role"].string) { return true }
        let block = message["metadata"]["blockType"].string
        return !block.isEmpty && !["agentMessage", "assistantMessage", "outputMessage", "text", "message", "musicCard", "locationCard", "sticker"].contains(block)
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
        // Index turn ownership once. Re-scanning the complete history for every
        // tool row was quadratic, especially in chats with many tool calls.
        var firstReplyByTurn: [TurnKey: Int] = [:]
        var nextReply = Array<Int?>(repeating: nil, count: messages.count)
        var nextLegacyReply = nextReply
        var next: Int?, nextLegacy: Int?
        for index in messages.indices.reversed() {
            nextReply[index] = next; nextLegacyReply[index] = nextLegacy
            if isUser(messages[index]) { next = nil; nextLegacy = nil }
            else if !isActivity(messages[index]) && !isLetterReminder(messages[index]) {
                next = index
                let turn = messages[index]["metadata"]["turnId"].string
                if turn.isEmpty { nextLegacy = index }
                else if let key = turnKey(messages[index]) { firstReplyByTurn[key] = index }
            }
        }
        var attached: [Int: [JSONValue]] = [:]
        var orphans: Set<Int> = []
        var previous: Int?, previousLegacy: Int?
        for index in messages.indices {
            let message = messages[index]
            if isUser(message) { previous = nil; previousLegacy = nil; continue }
            let turn = message["metadata"]["turnId"].string
            if isLetterReminder(message) { continue }
            if !isActivity(message) {
                previous = index
                if turn.isEmpty { previousLegacy = index }
                continue
            }
            let exact = turnKey(message).flatMap { firstReplyByTurn[$0] }
            let nearby = turn.isEmpty ? (nextReply[index] ?? previous) : (nextLegacyReply[index] ?? previousLegacy)
            if let target = exact ?? nearby { attached[target, default: []].append(message) }
            else { orphans.insert(index) }
        }
        let rows: [Row] = messages.indices.compactMap { index in
            if isActivity(messages[index]) {
                guard orphans.contains(index) else { return nil }
                return Row(id: messages[index].id, activity: true, messages: [messages[index]], activities: [messages[index]])
            }
            return Row(id: messages[index].id, activity: false, messages: [messages[index]], activities: attached[index] ?? [])
        }
        return combinedMediaRows(rows)
    }
    private static let timeLabels: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>(); cache.countLimit = 4096; return cache
    }()
    static func time(_ raw: String, full: Bool = false) -> String {
        guard let date = UserHistoryRecovery.parsedTime(raw) else { return "" }
        let today = Calendar.current.isDateInToday(date)
        let key = "\(raw)|\(full)|\(today)|\(TimeZone.current.identifier)|\(Locale.current.identifier)" as NSString
        if let cached = timeLabels.object(forKey: key) { return cached as String }
        let formatter = DateFormatter()
        formatter.dateFormat = full ? "M/d HH:mm:ss" : (today ? "HH:mm" : "MMM d, HH:mm")
        let label = formatter.string(from: date)
        timeLabels.setObject(label as NSString, forKey: key)
        return label
    }

}

enum ChatTerminalRecords {
    static func entries(_ messages: [JSONValue]) -> [JSONValue] {
        ChatTranscript.ordered(messages).filter { message in
            let execution = message["metadata"]["execution"]
            let kinds = ["commandExecution", "shellCall", "fileChange"]
            return execution != .null && (kinds.contains(execution["type"].string)
                || kinds.contains(message["metadata"]["blockType"].string))
        }
    }
}

private struct ChatQuestionSheet: View {
    @EnvironmentObject private var chat: ChatSession
    let request: ChatQuestionRequest
    @State private var answers: [String: String] = [:]
    @State private var other: Set<String> = []
    private var questions: [JSONValue] { request.packet["params"]["questions"].array }
    private var valid: Bool { (try? ChatUserInput.answer(request.packet, selections: answers)) != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 12) {
                            if !question["header"].string.isEmpty {
                                Text(question["header"].string).font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                            ChatMarkdownText(content: question["question"].string).font(.system(size: 17, weight: .semibold))
                            ForEach(Array(question["options"].array.enumerated()), id: \.offset) { _, option in
                                optionButton(question, label: option["label"].string, description: option["description"].string)
                            }
                            if question["isOther"].bool && !question["options"].array.isEmpty {
                                Button {
                                    other.insert(question.id); answers[question.id] = ""
                                } label: {
                                    Label("Other answer", systemImage: other.contains(question.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                }.buttonStyle(.plain).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                            if question["options"].array.isEmpty || other.contains(question.id) {
                                let value = Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 })
                                Group {
                                    if question["isSecret"].bool { SecureField("Your answer…", text: value) }
                                    else { TextField("Your answer…", text: value, axis: .vertical).lineLimit(1...4) }
                                }.padding(12).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }.padding(20)
            }.background { Background() }
                .safeAreaInset(edge: .bottom) {
                    Button { Task { _ = await chat.resolveQuestion(request.id, selections: answers) } } label: {
                        HStack { if chat.answeringQuestion { ProgressView() }; Text("Submit answer").font(.headline) }
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }.buttonStyle(.plain).vesperMaterial(.regularMaterial, in: Capsule())
                        .disabled(!valid || chat.answeringQuestion).padding(.horizontal, 20).padding(.bottom, 12)
                }
                .navigationTitle("Answer question").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Task { _ = await chat.resolveQuestion(request.id) } }.disabled(chat.answeringQuestion)
                } }
        }
    }
    private func optionButton(_ question: JSONValue, label: String, description: String) -> some View {
        let selected = !other.contains(question.id) && answers[question.id] == label
        return Button {
            other.remove(question.id); answers[question.id] = label
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(label).font(.subheadline.weight(.semibold))
                    if !description.isEmpty { Text(description).font(.caption).foregroundStyle(VesperTheme.muted) }
                }
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(selected ? VesperTheme.muted : .clear, lineWidth: 1) }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct QuestionToolRow: View {
    let message: JSONValue
    @State private var details = false
    private var record: JSONValue { message["metadata"]["userInput"] }
    var body: some View {
        Button { details = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench")
                Text("Question").font(.subheadline)
                Spacer()
                Text(record["status"].string.capitalized).font(.caption)
                Image(systemName: "chevron.right").font(.caption2)
            }.foregroundStyle(VesperTheme.muted).frame(minHeight: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Question tool, details")
            .sheet(isPresented: $details) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(record["questions"].array) { question in
                                VStack(alignment: .leading, spacing: 8) {
                                    ChatMarkdownText(content: question["question"].string).font(.headline)
                                    let answer = record["answers"][question.id].string
                                    if !answer.isEmpty { Text(answer).font(.subheadline).foregroundStyle(VesperTheme.muted) }
                                    else { Text("No answer recorded").font(.caption).foregroundStyle(VesperTheme.muted) }
                                }
                            }
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }.background { Background() }
                        .navigationTitle("Question").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
}

private struct ToolCallRow: View {
    let tool: JSONValue
    @State private var showingDetails = false
    private var title: String { tool["title"].string.isEmpty ? "Tool call" : tool["title"].string }
    private var hasOutput: Bool { !tool["output"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench").font(.system(size: 13))
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(tool["status"].string.capitalized).font(.caption2)
            if hasOutput { Image(systemName: "chevron.right").font(.system(size: 10)) }
        }
        .foregroundStyle(VesperTheme.muted)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
    var body: some View {
        Group {
            if hasOutput {
                Button { showingDetails = true } label: { row.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title + ", " + tool["status"].string + ", details")
            } else {
                row.accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(tool["status"].string.capitalized, systemImage: "wrench")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                        if !tool["output"].string.isEmpty {
                            Text(tool["output"].string).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        } else {
                            Text(["running", "inProgress"].contains(tool["status"].string) ? "Waiting for result…" : "No detailed result was saved.")
                                .font(.subheadline).foregroundStyle(VesperTheme.muted)
                        }
                        if tool["truncated"].bool { Text("Saved result is partial.").font(.caption).foregroundStyle(VesperTheme.muted) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .background { Background() }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}

private struct MiniTerminal: View {
    let execution: JSONValue
    var inlineDetails = false
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
            if inlineDetails { output.frame(maxHeight: 320) }
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

struct TerminalOperationGroup: View {
    let records: [JSONValue]
    var live = false
    @State private var details = false
    private var executions: [JSONValue] { records.map { $0["metadata"]["execution"] } }
    private var failed: Int { executions.filter { ["failed", "error", "declined", "interrupted", "cancelled"].contains($0["status"].string) }.count }
    private var finished: Int { executions.filter { ["completed", "succeeded", "success", "failed", "error", "declined", "interrupted", "cancelled"].contains($0["status"].string) }.count }
    private var running: Bool { live && executions.contains { ["running", "inProgress"].contains($0["status"].string) } }
    private var status: String { running ? "Running" : failed > 0 ? "\(failed) failed" : finished == records.count ? "Completed" : "Awaiting status" }
    private var color: Color { running ? .orange : failed > 0 ? .red : finished == records.count ? .green : VesperTheme.muted }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { details = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: running ? "terminal" : failed > 0 ? "exclamationmark.circle" : finished == records.count ? "checkmark.circle" : "clock")
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(records.count) operations · \(status)").font(.system(size: 14, weight: .semibold))
                        Text("Terminal").font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("View all \(records.count) terminal operations, \(status)")
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(executions.prefix(3).enumerated()), id: \.offset) { _, execution in
                    Text("$ " + (execution["command"].string.isEmpty ? execution["title"].string : execution["command"].string))
                        .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if records.count > 3 { Text("+\(records.count - 3) more").font(.caption) }
            }.padding(12).foregroundStyle(.white.opacity(0.9))
                .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 12))
            ProgressView(value: Double(finished), total: Double(max(1, records.count))).tint(color)
            Button { details = true } label: { Label("View all", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).frame(minHeight: 36) }.buttonStyle(.plain)
        }.padding(14).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .sheet(isPresented: $details) {
                NavigationStack {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(records) { item in MiniTerminal(execution: item["metadata"]["execution"], inlineDetails: true) }
                        }.padding()
                    }.background { Background() }
                        .navigationTitle("Terminal · \(records.count) operations").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
                }
            }
    }
}

private struct AssistantMessageHeading: View {
    let message: JSONValue
    var activities: [JSONValue] = []
    var liveEvents: [String] = []
    var isLive = false
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(activities.filter { $0["metadata"]["userInput"] != .null }) { item in QuestionToolRow(message: item) }
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Circle().fill(VesperTheme.muted).frame(width: 6, height: 6)
                    let time = ChatPresentation.time(ChatTranscript.timestamp(message), full: true)
                    if !time.isEmpty { Text(time) }
                    if isLive || message["status"].string == "streaming" {
                        ProgressView().controlSize(.mini)
                        Text("Thinking…")
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                }.font(.system(size: 12)).foregroundStyle(VesperTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("时间、思考摘要和工具调用").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                let terminal = ChatTerminalRecords.entries(activities)
                if !terminal.isEmpty { TerminalOperationGroup(records: terminal, live: isLive) }
                ForEach(activities.filter { $0["metadata"]["execution"] != .null && ChatTerminalRecords.entries([$0]).isEmpty }) { item in
                    ToolCallRow(tool: item["metadata"]["execution"])
                }
                let toolEvents = liveEvents.isEmpty ? message["metadata"]["toolEvents"].array.map { $0.string } : liveEvents
                let toolCards = ToolActivityRecords.cards(toolEvents)
                if !toolCards.isEmpty {
                    Text("Tool calls").font(.caption).foregroundStyle(VesperTheme.muted)
                    ForEach(toolCards) { card in ToolCallRow(tool: card) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thinking summary").font(.caption).foregroundStyle(VesperTheme.muted)
                    if !message["metadata"]["thoughtSummary"].string.isEmpty {
                        Text(message["metadata"]["thoughtSummary"].string).font(.system(size: 13)).textSelection(.enabled)
                    }
                    ForEach(activities.filter { $0["metadata"]["execution"] == .null && $0["metadata"]["userInput"] == .null }) { item in
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
    var messageActions: () -> [ChatMessageAction] = { [] }
    @State private var showing = false
    var body: some View {
        Group {
            Label(message["content"].string, systemImage: message["metadata"]["call"]["video"] == .bool(true) ? "video" : "phone").padding(16).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }.modifier(ChatLongPress(id: message.id, actions: messageActions, onTap: { showing = true }))
        .sheet(isPresented: $showing) {
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

private struct ChatTabSelectedKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var vesperChatTabSelected: Bool {
        get { self[ChatTabSelectedKey.self] }
        set { self[ChatTabSelectedKey.self] = newValue }
    }
}
private struct ChatIncomingFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
enum ChatReadVisibility {
    static func displayedIDs(frames: [String: CGRect], viewport: CGRect) -> Set<String> {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        return Set(frames.compactMap { id, frame in
            let visible = frame.intersection(viewport)
            // Lazy rows can be laid out outside the viewport. Require a readable
            // portion above the composer, rather than merely being loaded.
            return frame.width > 0 && frame.height > 0 && visible.width > 0
                && visible.height >= min(frame.height, 40) ? id : nil
        })
    }
}
