import SwiftUI
import UIKit
import PhotosUI
import Photos
import UniformTypeIdentifiers
import QuickLook
#if targetEnvironment(macCatalyst)
import ScreenCaptureKit
#endif

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
    let bottomControlsHeight: CGFloat
    let followsLatest: Bool
}

/// Clip horizontally while allowing the transcript behind the floating system bars.
private struct ChatMessageScrollClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 1000,
                    width: rect.width, height: rect.height + 2000))
    }
}

private struct AttachmentRowAlignment: ViewModifier {
    let single: Bool
    let user: Bool
    func body(content: Content) -> some View {
        if single { content.containerRelativeFrame(.horizontal, alignment: user ? .trailing : .leading) }
        else { content }
    }
}

private struct ChatScreenshotBubble: Identifiable {
    static let maximumSelection = 50
    enum Content {
        case text(String)
        case photos([JSONValue])
        case attachment(JSONValue)
        case card(String, String)
        case poke(String)
    }
    let id: String
    let user: Bool
    let content: Content

    static func bubbles(in row: ChatPresentation.Row, agentName: String) -> [Self] {
        guard !row.activity, !row.messages.contains(where: ChatPresentation.isLetterReminder) else { return [] }
        if let poke = ChatPokeNotice.text(row.presentedMessage, agentName: agentName) {
            let message = row.presentedMessage
            return [Self(id: message.id + "#poke", user: ChatPresentation.isUser(message), content: .poke(poke))]
        }
        return row.messages.flatMap(ChatBubbles.batchOriginals).flatMap { original -> [Self] in
            let user = ChatPresentation.isUser(original)
            func bubble(_ suffix: String, _ content: Content) -> Self {
                Self(id: original.id + "#" + suffix, user: user, content: content)
            }
            var result: [Self] = []
            let attachments = original["metadata"]["attachments"].array
            let photoIndices = attachments.indices.filter { attachments[$0]["type"].string.hasPrefix("image/") }
            for index in attachments.indices {
                let attachment = attachments[index]
                if attachment["type"].string.hasPrefix("image/") {
                    if index == photoIndices.first {
                        result.append(bubble("attachment-\(index)", .photos(photoIndices.map { attachments[$0] })))
                    }
                } else {
                    result.append(bubble("attachment-\(index)", .attachment(attachment)))
                }
            }
            if original["metadata"]["call"] != .null {
                result.append(bubble("call", .card("phone", original["content"].string)))
            }
            result += ChatBubbles.textParts(original).map {
                Self(id: $0.id, user: user, content: .text($0["content"].string))
            }
            for key in ["locationCard", "musicCard", "sticker"] where original["metadata"][key] != .null {
                let media = original["metadata"][key]
                let title = media[key == "musicCard" ? "title" : "name"].string
                result.append(bubble(key, .card(key == "musicCard" ? "music.note" : key == "sticker" ? "face.smiling" : "mappin", title.isEmpty ? key : title)))
            }
            return result
        }
    }
}

private struct ChatScreenshotSelectableRow<Content: View>: View {
    let bubbles: [ChatScreenshotBubble]
    @Binding var selecting: Bool
    @Binding var selectedIDs: Set<String>
    let onLimit: () -> Void
    let content: Content

    init(bubbles: [ChatScreenshotBubble], selecting: Binding<Bool>, selectedIDs: Binding<Set<String>>,
         onLimit: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.bubbles = bubbles
        self._selecting = selecting
        self._selectedIDs = selectedIDs
        self.onLimit = onLimit
        self.content = content()
    }

    var body: some View {
        if selecting {
            VStack(spacing: 9) {
                ForEach(bubbles) { bubble in
                    ChatScreenshotBubbleChoice(bubble: bubble, selected: selectedIDs.contains(bubble.id)) {
                        toggle(bubble.id)
                    }
                }
            }
        } else { content }
    }

    private func toggle(_ id: String) {
        var next = selectedIDs
        if next.contains(id) { next.remove(id) }
        else if next.count < ChatScreenshotBubble.maximumSelection { next.insert(id) }
        else { onLimit(); return }
        selectedIDs = next
    }
}

private struct ChatScreenshotBubbleChoice: View {
    let bubble: ChatScreenshotBubble
    let selected: Bool
    let toggle: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 25))
                .foregroundStyle(selected ? VesperTheme.accent : VesperTheme.muted)
                .frame(width: 42)
            HStack {
                if bubble.user { Spacer(minLength: 0) }
                content
                if !bubble.user { Spacer(minLength: 0) }
            }
        }
        .padding(.leading, 8).padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(selected ? "取消选择气泡" : "选择气泡")
        .accessibilityIdentifier("chat-screenshot-choice-\(bubble.id)")
    }
    @ViewBuilder private var content: some View {
        switch bubble.content {
        case .text(let text):
            ChatMarkdownText(content: text, selectable: false)
                .font(.system(size: 15)).lineSpacing(2)
                .modifier(ChatBubbleSurface(user: bubble.user))
        case .photos(let photos):
            ChatPhotoStack(photos: photos, alignment: bubble.user ? .trailing : .leading)
                .allowsHitTesting(false)
        case .attachment(let attachment):
            Label(attachment["name"].string.isEmpty ? "附件" : attachment["name"].string,
                  systemImage: attachment["type"].string.hasPrefix("audio/") ? "waveform" : "doc")
                .font(.system(size: 14)).padding(12).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .card(let symbol, let title):
            Label(title, systemImage: symbol)
                .font(.system(size: 14)).padding(12).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .poke(let text):
            Text(text).font(.system(size: 12)).foregroundStyle(VesperTheme.muted)
        }
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

struct ChatAttachmentPreview: View {
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

// Geometry changes during scrolling are read receipts, not visual state. Updating
// these fields must not invalidate the transcript and re-layout every bubble.
final class ChatReadGeometry {
    var incomingFrames: [String: CGRect] = [:]
    var scrollFrame = CGRect.zero
    var headerFrame = CGRect.zero
    var composerFrame = CGRect.zero
}

struct ChatProfileAvatar: View, Equatable {
    let source: String
    let name: String
    let role: String
    let baseURL: String
    @State private var image: UIImage?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.name == rhs.name && lhs.role == rhs.role && lhs.baseURL == rhs.baseURL
    }
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { placeholder }
        }
        .frame(width: 40, height: 40).clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("\(name) avatar")
        .task(id: ChatAvatarSource(source: source, baseURL: baseURL)) {
            let preview = await ChatAvatarImageCache.shared.image(for: ChatAvatarSource(source: source, baseURL: baseURL))
            guard !Task.isCancelled else { return }
            image = preview
        }
    }
    private var placeholder: some View {
        ZStack {
            Circle().fill(VesperTheme.muted.opacity(role == "user" ? 0.12 : 0.25))
            Image(systemName: "person.fill").font(.system(size: 19)).foregroundStyle(VesperTheme.muted)
        }
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.vesperChatTabSelected) private var chatTabSelected
    @ObservedObject private var inbox = ChatInbox.shared
    @State private var chatVisible = false
    @State private var barkPresenceOwner = UUID().uuidString
    @State private var readGeometry = ChatReadGeometry()
    @State private var headerActionsExpanded = false
    @State private var selectingScreenshot = false
    @State private var screenshotSelection: Set<String> = []
    @State private var screenshotPreparing = false
    @State private var screenshotImage: UIImage?
    @State private var screenshotNotice: String?

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
    @State private var sentPokeEventID = ""
    @EnvironmentObject private var draftStore: ChatComposer
    private var draft: String { get { draftStore.draft } nonmutating set { draftStore.draft = newValue } }
    @State private var history = false
    @State private var historyTab = 0
    @State private var query = ""
    @State private var renaming: JSONValue?
    @State private var renameText = ""
    @State private var removingConversation: JSONValue?
    @State private var modelPicker = false
    @State private var strengthPicker = false
    @State private var compactNotice = false
    @State private var connectionDetails = false
    @State private var terminalVisible = false
    @State private var screenShareVisible = false
    #if !targetEnvironment(macCatalyst)
    #endif
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
    @State private var bottomControlsHeight: CGFloat = 0
    @State private var locationPicker = false
    @State private var confirmNew = false
    @State private var deleting: JSONValue?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    private var images: [Data] { get { draftStore.images } nonmutating set { draftStore.images = newValue } }
    private var files: [ChatFile] { get { draftStore.files } nonmutating set { draftStore.files = newValue } }
    @State private var loadingPhotos = false
    @FocusState private var focused: Bool
    private var chatContent: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.hasOlderMessages { Button(chat.loadingOlder ? "Loading…" : "Load earlier messages") { followsLatest = false; Task { await chat.loadOlder() } }.disabled(chat.loadingOlder) }
                        if chat.messages.isEmpty && chat.queuedMessages.isEmpty { Text("A little space for us.").font(VesperTheme.title(30)).foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity).padding(.top, 70) }
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
                                } else if row.activity && row.activities.allSatisfy({ $0["metadata"]["userInput"] != .null }) {
                                    QuestionToolRow(message: message).background(incomingReadFrame(row))
                                }
                                else if row.activity {
                                    AssistantMessageHeading(message: message, activities: row.activities, liveEvents: message.id == chat.liveHeadingID ? chat.events : [], isLive: message.id == chat.liveHeadingID)
                                        .background(incomingReadFrame(row))
                                }
                                else {
                                    ChatScreenshotSelectableRow(bubbles: selectingScreenshot ? ChatScreenshotBubble.bubbles(in: row, agentName: store.agentDisplayName) : [], selecting: $selectingScreenshot,
                                        selectedIDs: $screenshotSelection,
                                        onLimit: { screenshotNotice = "一次最多选择 \(ChatScreenshotBubble.maximumSelection) 个气泡。" }) {
                                        messageRow(row)
                                    }.id(row.id).background(incomingReadFrame(row))
                                }
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
                        if !chat.sending {
                            ForEach(chat.queuedMessages) { entry in
                                ChatQueuedBubble(message: entry, canRemove: !chat.busy) { chat.removeQueuedMessage(entry.id) }.id(entry.id)
                            }
                        }
                        Color.clear.frame(height: bottomControlsHeight + 14).id("bottom")
                    }.padding(.horizontal, 20).padding(.top, 62)
                    .background(GeometryReader { geometry in Color.clear.preference(key: ChatBottomPosition.self, value: geometry.frame(in: .named("chat-scroll")).maxY) })
                    .opacity(positionedConversationID == chat.conversationID || chat.messages.isEmpty ? 1 : 0)
                }.scrollDismissesKeyboard(.interactively)
                // Let scrolled bubbles remain visible behind the status bar and header.
                .scrollClipDisabled()
                .transparentChatBottom()
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    readGeometry.scrollFrame = frame; markDisplayedMessages()
                }
                .onPreferenceChange(ChatIncomingFrames.self) { frames in
                    readGeometry.incomingFrames = frames; markDisplayedMessages()
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
                // Floating controls share the full-height transcript canvas.
                // The measured bottom spacer keeps the latest bubble unobscured.
                    VStack(spacing: 0) {
                        Group {
                            if selectingScreenshot { screenshotSelectionBar }
                            else { composer }
                        }
                        if stickerPicker {
                            StickerLibraryView(compact: true, onBack: { stickerPicker = false; drawer = true }) { sticker in
                                pendingSticker = sticker
                                stickerPicker = false; drawer = false
                            }
                            .frame(height: attachmentPanelHeight).background(.regularMaterial)
                        } else if drawer {
                            attachmentDrawer
                                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { attachmentPanelHeight = $0 }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                        bottomControlsHeight = frame.height
                        readGeometry.composerFrame = frame; markDisplayedMessages()
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
                .clipShape(ChatMessageScrollClip())
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
                    images = []; files = []; selectedPhotos = []; pendingMusic = nil; pendingSticker = nil
                    voiceRecorder.cancel(); drawer = false; stickerPicker = false
                    selectingScreenshot = false; screenshotSelection = []; screenshotImage = nil
                }
            }
            if headerActionsExpanded {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { headerActionsExpanded = false } }
                    .accessibilityLabel("收起聊天选项")
                    .accessibilityAddTraits(.isButton)
            }
            // Only the controls intercept touches; the gaps reveal the transcript.
            header.zIndex(1)
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    readGeometry.headerFrame = frame; markDisplayedMessages()
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
                         bottomControlsHeight: bottomControlsHeight,
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
        var viewport = readGeometry.scrollFrame
        let visibleTop = max(viewport.minY, readGeometry.headerFrame.maxY)
        viewport.size.height = max(0, viewport.maxY - visibleTop)
        viewport.origin.y = visibleTop
        if readGeometry.composerFrame.height > 0 { viewport.size.height = max(0, min(viewport.maxY, readGeometry.composerFrame.minY) - viewport.minY) }
        let ids = ChatReadVisibility.displayedIDs(frames: readGeometry.incomingFrames, viewport: viewport)
        inbox.markDisplayed(conversation: chat.conversationID, messageIDs: ids)
    }
    @ViewBuilder private func incomingReadFrame(_ row: ChatPresentation.Row) -> some View {
        let ids = ChatReadVisibility.receiptIDs(for: row)
        if !ids.isEmpty {
            GeometryReader { geometry in
                Color.clear.preference(key: ChatIncomingFrames.self, value: Dictionary(
                    ids.map { ($0, geometry.frame(in: .global)) }, uniquingKeysWith: { first, _ in first }))
            }
        }
    }
    private var observedChatContent: some View {
        chatContent
        .environmentObject(actionMenu)
        .overlay { ChatActionOverlay(menu: actionMenu).allowsHitTesting(actionMenu.selection != nil) }
        .onChange(of: chat.conversationID) { _, _ in actionMenu.selection = nil; quoteJumpPart = nil }
        .onAppear { chatVisible = true; markDisplayedMessages(); updateBarkVisibility() }
        .onDisappear { chatVisible = false; updateBarkVisibility() }
        .onChange(of: inbox.incoming) { _, _ in markDisplayedMessages() }
        .task(id: chatVisible && chatTabSelected && phase == .active) {
            guard chatVisible && chatTabSelected && phase == .active else { return }
            while !Task.isCancelled {
                await chat.refreshVisibleHistory()
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
            }
        }
        .task(id: pendingScreenReplyID + (chat.busy ? ":busy" : ":idle")) {
            let id = pendingScreenReplyID
            guard !id.isEmpty, !chat.busy else { return }
            await chat.receiveScreenReply(id)
        }
        .onChange(of: phase) { _, _ in markDisplayedMessages(); updateBarkVisibility() }
        .onChange(of: chatTabSelected) { _, _ in markDisplayedMessages(); updateBarkVisibility() }
        .onChange(of: chat.conversationID) { _, _ in updateBarkVisibility() }
        .onReceive(NotificationCenter.default.publisher(for: .init("BarkConfigurationChanged"))) { _ in updateBarkVisibility() }
        .onChange(of: positionedConversationID) { _, _ in markDisplayedMessages() }
    }
    private var pendingScreenReplyID: String {
        guard chatVisible, chatTabSelected, phase == .active,
              let cover = inbox.incoming.first(where: { $0.conversationId == chat.conversationID }),
              cover.messageId.hasPrefix("screen:"), !chat.messages.contains(where: { $0.id == cover.messageId }) else { return "" }
        return cover.messageId
    }
    private func updateBarkVisibility() {
        guard store.activeBackend == .vps else { return }
        ChatBarkPresence.shared.update(api: store.api, conversation: chat.conversationID,
            visible: chatVisible && chatTabSelected && phase == .active && chat.voiceCallContext == nil,
            owner: barkPresenceOwner)
    }
    private var photoContent: some View {
        observedChatContent
        .task {
            chat.configure(store)
            guard restoreLatest else { return }
            if chat.messages.isEmpty && chat.conversations.isEmpty && chat.status.isEmpty {
                _ = chat.previewConversation()
            }
            if chat.conversations.isEmpty { await chat.loadConversations() }
            if chat.showingCachedHistory || (chat.messages.isEmpty && !chat.conversations.contains(where: { $0.id == chat.conversationID })) {
                await chat.openMainRoom()
            }
        }
        .onChange(of: focused) { _, value in if value { drawer = false; stickerPicker = false } }
        .onChange(of: speech.text) { _, text in draft = speechBase + (speechBase.isEmpty || text.isEmpty ? "" : " ") + text }
        .onChange(of: voiceRecorder.error) { _, error in if let error { chat.error = error } }
        .onChange(of: speech.error) { _, error in if let error { chat.error = error } }
        .onDisappear { speech.stop(); voiceRecorder.cancel() }
        .sheet(isPresented: Binding(get: { screenshotImage != nil }, set: { if !$0 { screenshotImage = nil } })) {
            if let screenshotImage {
                ChatScreenshotPreview(image: screenshotImage, api: store.api) { destination in
                    screenshotSelection = []; selectingScreenshot = false; self.screenshotImage = nil
                    screenshotNotice = "截图已保存到" + (destination == .system ? "系统相册。" : "Vesper 相册。")
                }
            }
        }
        .alert("聊天截图", isPresented: Binding(get: { screenshotNotice != nil }, set: { if !$0 { screenshotNotice = nil } })) {
            Button("好") { screenshotNotice = nil }
        } message: { Text(screenshotNotice ?? "") }
        .photosPicker(isPresented: $photoPicker, selection: $selectedPhotos, maxSelectionCount: max(1, 5 - images.count - files.count), matching: .any(of: [.images, .videos]))
        .onChange(of: selectedPhotos) { _, picks in
            guard !picks.isEmpty else { return }; loadingPhotos = true
            Task {
                let room = chat.conversationID, backend = store.api.baseURL
                for pick in picks {
                    do {
                        if pick.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                            guard !files.contains(where: { $0.mime.hasPrefix("video/") }) else { throw ServiceError(message: "一次先发一个短视频就好。") }
                            guard let video = try await pick.loadTransferable(type: ChatPickedVideo.self) else { throw ServiceError(message: "无法读取这个视频。") }
                            defer { try? FileManager.default.removeItem(at: video.url.deletingLastPathComponent()) }
                            let file = try await prepareVideo(video.url)
                            guard chat.conversationID == room, store.api.baseURL == backend else { break }
                            if files.count < 5 { files.append(file) }
                        } else {
                            guard let bytes = try await pick.loadTransferable(type: Data.self) else { throw ServiceError(message: "Could not read this photo.") }
                            let jpeg = try await ChatImageProcessing.prepare(bytes)
                            guard chat.conversationID == room, store.api.baseURL == backend else { break }
                            if images.count + files.count < 5 { images.append(jpeg) }
                        }
                    } catch { chat.error = error.localizedDescription }
                }
                selectedPhotos = []; loadingPhotos = false
            }
        }
    }
    private var attachmentContent: some View {
        photoContent
        .fullScreenCover(isPresented: $cameraPicker) {
            ChatCameraPicker(completion: { data in if let data, images.count + files.count < 5 { images.append(data) }; cameraPicker = false },
                             onError: { chat.error = $0 }).ignoresSafeArea()
        }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            loadingPhotos = true
            Task {
              defer { loadingPhotos = false }
              let room = chat.conversationID, backend = store.api.baseURL
              do {
                for url in try result.get() {
                    guard images.count + files.count < 5 else { break }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    if mime.hasPrefix("video/") {
                        guard !files.contains(where: { $0.mime.hasPrefix("video/") }) else { throw ServiceError(message: "一次先发一个短视频就好。") }
                        let file = try await prepareVideo(url)
                        guard chat.conversationID == room, store.api.baseURL == backend else { break }
                        files.append(file); continue
                    }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    let maximum = 32
                    guard size <= maximum * 1024 * 1024 else { throw ServiceError(message: "Choose files under \(maximum) MB.") }
                    let data = try Data(contentsOf: url)
                    guard data.count <= maximum * 1024 * 1024 else { throw ServiceError(message: "Choose files under \(maximum) MB.") }
                    files.append(ChatFile(name: url.lastPathComponent, mime: mime, data: data))
                }
              } catch { chat.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $locationPicker) { locationSheet }
        .sheet(isPresented: $musicPicker) { musicSheet }
        .sheet(isPresented: $history) { historySheet }
        .confirmationDialog("Start a new chat and clear this draft?", isPresented: $confirmNew) { Button("New chat", role: .destructive) { newChat() } }
        .confirmationDialog("删除这条消息？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("同步删除", role: .destructive) { if let part = deleting { Task { await chat.deleteMessagePart(part) } }; deleting = nil }
        }
    }
    private func prepareVideo(_ url: URL) async throws -> ChatFile {
        var (file, audio) = try await ChatVideoProcessing.prepare(url)
        if let audio {
            defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
            let recognizer = VoiceMessageRecorder()
            let text = await recognizer.transcribeVideoAudio(audio)
            recognizer.cancel()
            file.transcript = text.isEmpty ? nil : text
            file.videoAudioNote = text.isEmpty ? "Audio exists but speech recognition was unavailable or found no speech. Do not invent sounds, music, or dialogue." : "Only recognized speech is available; non-speech audio was not analyzed."
        }
        try Task.checkCancellation()
        return file
    }
    var body: some View {
        attachmentContent
        .sheet(isPresented: $connectionDetails) {
            ChatIssueSheet(
                issues: chat.issueDetails,
                retry: { action in
                    if action == .models { Task { await chat.loadModels() } }
                    else if action == .sync { chat.retryHistorySync() }
                    else { chat.retryConnection() }
                },
                dismiss: { chat.dismissIssue($0) },
                close: { connectionDetails = false })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $screenShareVisible) {
            #if targetEnvironment(macCatalyst)
            MacChatScreenShareSheet(conversationID: chat.conversationID,
                                    conversationTitle: chat.conversations.first(where: { $0.id == chat.conversationID })?["title"].string ?? "Chat")
                .environmentObject(store).environmentObject(chat)
                .presentationDetents([.medium, .large])
            #else
            ChatScreenShareSheet(conversationID: chat.conversationID,
                                 conversationTitle: chat.conversations.first(where: { $0.id == chat.conversationID })?["title"].string ?? "Chat")
                .environmentObject(store).environmentObject(chat)
                .presentationDetents([.medium, .large])
            #endif
        }
        .sheet(isPresented: $terminalVisible) {
            ChatTerminalView(conversationID: chat.conversationID).environmentObject(chat)
                .presentationDetents(store.activeBackend == .vps ? [.large] : [.medium, .large])
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
                    HStack {
                        Button("Decline", role: .cancel) { Task { await chat.resolveApproval(accept: false) } }
                        Spacer()
                        Button { Task { await chat.resolveApproval(accept: true) } } label: {
                            Text("Allow once").fontWeight(.semibold)
                                .foregroundStyle(VesperTheme.palette == .black ? Color.black : Color.white)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .background(VesperTheme.ink, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding() }.navigationTitle("Approval")
            }.interactiveDismissDisabled()
        }
    }
    @Environment(\.dismiss) private var dismissChat
    private var header: some View {
        // Center the avatar pair on the full header, independently of either side.
        HStack(spacing: 5) {
            profileAvatar("user", fallbackName: "Vera", trigger: chat.agentPokeEventID)
                .accessibilityLabel("我的头像")
            Button {
                Task { _ = await chat.sendPoke { sentPokeEventID = UUID().uuidString } }
            } label: { profileAvatar("agent", fallbackName: store.agentDisplayName, trigger: sentPokeEventID) }
                .accessibilityLabel("拍一拍" + store.agentDisplayName)
                .accessibilityIdentifier("chat-poke-agent")
                .disabled(chat.busy || chat.unconfirmedSend || chat.showingCachedHistory || chat.openingMainRoom || store.loading)
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
                ChatHeaderMenu(expanded: $headerActionsExpanded, onTerminal: { terminalVisible = true }, onScreenShare: { screenShareVisible = true }, onSelectMessages: { beginScreenshotSelection() }, showsVPSDisplay: store.activeBackend == .vps)
            }
            .font(.system(size: 20)).padding(.horizontal, 12).padding(.vertical, 4)
    }
    private func profileAvatar(_ role: String, fallbackName: String, trigger: String) -> some View {
        let profile = store.document("profile")
        let source = profile["\(role)Avatar"].string
        let name = profile["\(role)Name"].string
        return ChatProfileAvatar(source: source, name: name.isEmpty ? fallbackName : name,
                                 role: role, baseURL: store.baseURL).equatable()
            .modifier(ChatAvatarPatMotion(trigger: trigger))
    }
    private var selectedScreenshotBubbles: [ChatScreenshotBubble] {
        chat.presentation.rows.flatMap { ChatScreenshotBubble.bubbles(in: $0, agentName: store.agentDisplayName) }
            .filter { screenshotSelection.contains($0.id) }
    }
    private var screenshotSelectionBar: some View {
        HStack(spacing: 14) {
            Button("取消") { selectingScreenshot = false; screenshotSelection = [] }
                .frame(minHeight: 44)
            Spacer(minLength: 0)
            Text(screenshotSelection.isEmpty ? "点左侧圆圈选择" : "已选 \(screenshotSelection.count)/\(ChatScreenshotBubble.maximumSelection) 个气泡")
                .font(.subheadline).foregroundStyle(VesperTheme.muted)
            Button {
                Task { await prepareScreenshot() }
            } label: {
                if screenshotPreparing { ProgressView().frame(minWidth: 76) }
                else { Text("预览截图").fontWeight(.semibold) }
            }.disabled(screenshotSelection.isEmpty || screenshotPreparing)
                .frame(minHeight: 44)
        }.padding(.horizontal, 20).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 16).padding(.bottom, 8)
    }
    private func beginScreenshotSelection() {
        focused = false; drawer = false; stickerPicker = false; actionMenu.selection = nil
        screenshotSelection = []; selectingScreenshot = true
    }
    @MainActor private func prepareScreenshot() async {
        guard !screenshotPreparing else { return }
        let bubbles = selectedScreenshotBubbles
        guard !bubbles.isEmpty else { return }
        screenshotPreparing = true
        defer { screenshotPreparing = false }
        do {
            screenshotImage = try await ChatScreenshotExport.render(bubbles: bubbles)
        } catch { screenshotNotice = "生成截图失败：" + error.localizedDescription }
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
                       onDelete: { deleting = row.messages.first },
                       sourceMessages: row.messages,
                       onPartFavorite: { part in Task { await favorite(part) } },
                       onPartDelete: { deleting = $0 },
                       onReply: { part in
                           draftStore.replyTo = ChatBubbles.quote(part, conversationID: chat.conversationID)
                           focused = true
                       },
                       onOpenQuote: { quote in
                           positionedJumpMessageID = nil
                           followsLatest = false
                           quoteJumpRevision += 1
                           chat.jumpMessageID = nil
                           quoteJumpPart = nil
                           Task {
                               let id = quote["messageId"].string
                               await chat.reveal(id)
                               if let original = chat.messages.first(where: { $0.id == id }) {
                                   quoteJumpPart = ChatBubbles.quoteTarget(quote, original: original)
                               } else { chat.error = "原消息已删除或暂时无法加载。" }
                           }
                       }, store: store, chat: chat, conversationID: chat.conversationID,
                       pokeText: ChatPokeNotice.text(message, agentName: chat.contactName))
            .equatable()
    }
    private var composer: some View {
        VStack(spacing: 0) {
            composerControls
            composerInput
        }.padding(.vertical, 8)
    }
    private var composerControls: some View {
        HStack(spacing: 6) {
            Button {
                focused = false; drawer = false; stickerPicker = false
                strengthPicker = false; modelPicker.toggle()
            } label: {
                composerControlLabel(chat.model.isEmpty ? "Model" : chat.model, symbol: "cpu")
            }
            .disabled(chat.callActive || store.loading)
            .accessibilityLabel("Model")
            .accessibilityValue(chat.model.isEmpty ? "Default" : chat.model)
            .accessibilityIdentifier("chat-model-picker")
            .popover(isPresented: $modelPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                ChatModelPopover(initialPage: .model).environmentObject(store).environmentObject(chat)
                    .presentationCompactAdaptation(.popover)
                    .task { chat.configure(store); await chat.loadModels(forceRefresh: false) }
            }
            Button {
                focused = false; drawer = false; stickerPicker = false
                modelPicker = false; strengthPicker.toggle()
            } label: {
                composerControlLabel(chat.effort.isEmpty ? "Auto" : chat.effort == "xhigh" ? "X-high" : chat.effort.capitalized,
                                     symbol: "sparkles")
            }
            .disabled(chat.callActive || store.loading)
            .accessibilityLabel("Strength")
            .accessibilityValue(chat.effort.isEmpty ? "Auto" : chat.effort)
            .accessibilityIdentifier("chat-strength-picker")
            .popover(isPresented: $strengthPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                ChatModelPopover(initialPage: .strength).environmentObject(store).environmentObject(chat)
                    .presentationCompactAdaptation(.popover)
                    .task { chat.configure(store); await chat.loadModels(forceRefresh: false) }
            }
            Button {
                focused = false; modelPicker = false; strengthPicker = false
                Task {
                    do {
                        try await chat.compactContextNow()
                        compactNotice = true
                        try? await Task.sleep(for: .seconds(3))
                        compactNotice = false
                    } catch { chat.error = error.localizedDescription }
                }
            } label: {
                composerControlLabel(chat.manualCompactionRunning ? "Compacting" : compactNotice ? "Compacted" : "Compact",
                                     symbol: "arrow.triangle.2.circlepath")
            }
            .disabled(chat.busy || chat.manualCompactionRunning || chat.activeThreadID == nil)
            .accessibilityLabel("Compact context now")
            .accessibilityIdentifier("chat-compact-now")
            Spacer(minLength: 0)
            if !chat.queuedMessages.isEmpty && !chat.sending {
                Button {
                    focused = false
                    Task { _ = await chat.sendCollectedMessages() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 12))
                        Text("\(chat.queuedMessages.count)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 9).frame(height: 34)
                    .vesperGlass(in: Capsule(), interactive: true)
                    .frame(minHeight: 44)
                }
                .disabled(chat.busy || chat.unconfirmedSend || chat.showingCachedHistory || chat.openingMainRoom || store.loading)
                .accessibilityLabel("开始回复，共\(chat.queuedMessages.count)条待发送消息")
                .accessibilityHint("一起发送已攒好的消息，输入框中的草稿会保留")
                .accessibilityIdentifier("chat-reply-collected")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
    }
    private func composerControlLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(title).lineLimit(1).minimumScaleFactor(0.75)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 9)
        .frame(height: 34)
        .vesperGlass(in: Capsule(), interactive: true)
        .frame(minHeight: 44)
    }
    private var composerInput: some View {
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
                    ChatDraftPhoto(data: data, size: 60).overlay(alignment: .topTrailing) {
                        Button { if images.indices.contains(index) { images.remove(at: index) } } label: { Image(systemName: "xmark.circle.fill") }.disabled(chat.busy)
                    }
                } } }
            }
            if loadingPhotos { HStack(spacing: 8) { ProgressView(); Text("正在准备照片或视频…").font(.caption) } }
            ForEach(files) { file in HStack { Label(file.name, systemImage: file.mime.hasPrefix("video/") ? "video" : "doc").lineLimit(1); Spacer(); Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark") }.disabled(chat.busy) }.font(.caption) }
            HStack(alignment: .bottom, spacing: 4) {
                Button { focused = false; speech.stop(); withAnimation(.easeOut(duration: 0.2)) { if stickerPicker { stickerPicker = false; drawer = false } else { drawer.toggle() } } } label: { Image(systemName: drawer || stickerPicker ? "xmark" : "plus").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Attachments").disabled(chat.busy)
                ChatDraftField(text: draftStore.text, listening: speech.listening, focused: $focused)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                Button { focused = false; drawer = false; stickerPicker = false; store.musicPlayer?.pause(); Task { if voiceRecorder.recording { await voiceRecorder.stop() } else { await voiceRecorder.start(context: chat.messages.filter { !ChatPresentation.isActivity($0) }.suffix(12).map { $0["content"].string } + [draft]) } } } label: { Image(systemName: voiceRecorder.recording ? "stop.circle.fill" : "mic").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel(voiceRecorder.recording ? "Finish voice message" : "Record voice message").disabled(chat.busy || voiceRecorder.processing || voiceRecorder.file != nil)
                if chat.busy { Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40) } }
                else {
                    ChatSendButton(text: draftStore.text,
                                   hasNonTextPayload: !images.isEmpty || !files.isEmpty || voiceRecorder.file != nil || pendingMusic != nil || pendingSticker != nil,
                                   blocked: store.loading || chat.showingCachedHistory || chat.openingMainRoom || voiceRecorder.recording || voiceRecorder.processing || loadingPhotos,
                                   action: send)
                        #if targetEnvironment(macCatalyst)
                        .keyboardShortcut(.return, modifiers: .command)
                        #endif
                }
            }
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2).vesperGlass(in: RoundedRectangle(cornerRadius: 22)).padding(.horizontal, 12)
    }
    private var attachmentDrawer: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 20) {
            drawerItem("Album", "photo") { photoPicker = true }
            drawerItem("Camera", "camera.fill") { if UIImagePickerController.isSourceTypeAvailable(.camera) { cameraPicker = true } else { chat.error = "Camera unavailable on this device." } }
            drawerItem("File", "folder.fill") { filePicker = true }
            drawerItem("Call", "phone.fill") { openCall() }
                drawerItem("Location", "mappin.circle.fill") { locationPicker = true }
                drawerItem("Music", "music.note") { musicPicker = true }
                drawerItem("Stickers", "face.smiling") { stickerPicker = true }
        }.padding(20).background(.regularMaterial)
            .accessibilityIdentifier("chat-attachment-panel")
    }
    private func drawerItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { drawer = false; action() } label: { VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 26)).frame(width: 58, height: 58).vesperGlass(in: RoundedRectangle(cornerRadius: 16), interactive: true); Text(title).font(.system(size: 12)) }.frame(maxWidth: .infinity) }.buttonStyle(.plain).disabled(chat.busy || loadingPhotos || ((title == "Album" || title == "Camera") && images.count + files.count >= 5))
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
                        Button { history = false; if draft.isEmpty && images.isEmpty && files.isEmpty { newChat() } else { confirmNew = true } } label: { Label("New Chat", systemImage: "plus") }.disabled(chat.busy)
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
            chat.memoryStatus = "已生成待核对候选，稍后会弹出核对。"
            NotificationCenter.default.post(name: .init("VesperMemoryCandidateProposed"), object: nil)
        } catch { chat.error = error.localizedDescription }
    }
    private func isFavorite(_ message: JSONValue) -> Bool { ChatFavorites.existing(message.id, conversationID: chat.conversationID, in: store) != nil }
    private func favorite(_ message: JSONValue) async {
        if let item = ChatFavorites.existing(message.id, conversationID: chat.conversationID, in: store) { _ = await store.remove("favorites", id: item.id); return }
        let title = chat.conversations.first(where: { $0.id == chat.conversationID })?["title"].string ?? "Chat"
        _ = await ChatFavorites.save(message, conversationID: chat.conversationID, title: title, in: store)
    }
    private func newChat() { voiceRecorder.cancel(); speech.stop(); Task { if await chat.createConversation() { draft = ""; images = []; files = []; pendingMusic = nil; pendingSticker = nil; draftStore.replyTo = nil } } }
    private func openCall() {
        guard !chat.busy, !chat.sending, !chat.unconfirmedSend else {
            chat.error = "等当前回复完成后再拨号。"
            return
        }
        voiceRecorder.cancel(); speech.stop(); focused = false; drawer = false; stickerPicker = false
        NativeCallPresentation.shared.open(initiator: "user")
    }
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
    var onPartDelete: (JSONValue) -> Void = { _ in }
    var onReply: (JSONValue) -> Void = { _ in }
    var onOpenQuote: (JSONValue) -> Void = { _ in }
    @StateObject private var downloader = ChatAttachmentDownloader()
    @State private var reactionTarget: JSONValue?
    // Runtime references are used by actions. Observe row inputs rather than every
    // streaming update, so unchanged old messages can retain their rendered views.
    let store: AppStore
    let chat: ChatSession
    let conversationID: String
    var pokeText: String? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.chat === rhs.chat && lhs.conversationID == rhs.conversationID &&
        lhs.isLive == rhs.isLive && lhs.message == rhs.message && lhs.mediaMessages == rhs.mediaMessages && lhs.activities == rhs.activities && lhs.liveEvents == rhs.liveEvents &&
        lhs.replyIsRunning == rhs.replyIsRunning && lhs.favorite == rhs.favorite && lhs.sourceMessages == rhs.sourceMessages &&
        lhs.saving == rhs.saving && lhs.busy == rhs.busy && lhs.highlighted == rhs.highlighted && lhs.pokeText == rhs.pokeText
    }
    private var originals: [JSONValue] { (sourceMessages.isEmpty ? [message] : sourceMessages).flatMap { ChatBubbles.batchOriginals($0) } }
    var body: some View {
        Group {
            if let pokeText {
                Text(pokeText).font(.system(size: 12)).foregroundStyle(VesperTheme.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .modifier(ChatLongPress(id: message.id, actions: { actions(message) }))
                    .accessibilityIdentifier("chat-poke-notice")
            } else { bubbles }
        }.modifier(ChatAttachmentDownloadPresenter(downloader: downloader))
            .sheet(item: $reactionTarget) { part in
                ChatReactionPicker(selected: reaction(part)) { emoji in
                    Task { await chat.react(to: part, emoji: emoji) }
                }
            }
    }
    private var bubbles: some View {
        let user = ChatPresentation.isUser(message)
        return VStack(alignment: .leading, spacing: 0) {
            if !user {
                AssistantMessageHeading(message: message, activities: activities, liveEvents: liveEvents, isLive: isLive,
                    tokenUsage: (sourceMessages.isEmpty ? [message] : sourceMessages).reversed()
                        .first(where: { $0["metadata"]["tokenUsage"] != .null })?["metadata"]["tokenUsage"] ?? .null)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
            HStack(alignment: .top, spacing: 0) {
                if user { Spacer(minLength: 42) }
                VStack(alignment: user ? .trailing : .leading, spacing: 5) {
                    ForEach(originals) { original in
                    if ChatBubbles.textParts(original).isEmpty, original["metadata"]["replyTo"] != .null {
                        ChatQuotePreview(quote: original["metadata"]["replyTo"]) { onOpenQuote(original["metadata"]["replyTo"]) }
                    }
                    sharedContent(original, user: user)
                    if original["metadata"]["musicCard"] == .null && original["status"].string != "streaming" {
                        ForEach(ChatMusicShare.links(in: original["content"].string)) { track in
                            let part = ChatBubbles.part(original, key: track.id, text: track["appleMusicURL"].string, metadata: .object(["musicCard": track]))
                            ChatMusicLinkCard(track: track).modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                                .modifier(reactionBadge(part)).id(part.id)
                        }
                    }
                    if original["metadata"]["call"] != .null {
                        CallRecordButton(message: original, messageActions: { actions(original) })
                            .modifier(reactionBadge(original))
                    }
                    ForEach(ChatBubbles.textParts(original)) { part in
                        let standaloneLink = original["status"].string != "streaming" && ChatLinkPreviews.isStandaloneLink(part["content"].string)
                        if standaloneLink, part["metadata"]["replyTo"] != .null {
                            ChatQuotePreview(quote: part["metadata"]["replyTo"]) { onOpenQuote(part["metadata"]["replyTo"]) }
                        }
                        if !standaloneLink {
                            VStack(alignment: .leading, spacing: 8) {
                                if part["metadata"]["replyTo"] != .null {
                                    ChatQuotePreview(quote: part["metadata"]["replyTo"]) { onOpenQuote(part["metadata"]["replyTo"]) }
                                }
                                ChatMarkdownText(content: part["content"].string, selectable: false)
                                    .font(.system(size: 15)).lineSpacing(2).multilineTextAlignment(.leading)
                            }
                            .modifier(ChatBubbleSurface(user: user))
                            .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                            .modifier(reactionBadge(part))
                            .id(part.id)
                        }
                        if original["status"].string != "streaming" {
                            ForEach(ChatLinkPreviews.urls(in: part["content"].string), id: \.absoluteString) { url in
                                ChatLinkPreviewCard(url: url)
                                    .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                                    .modifier(reactionBadge(part))
                                    .id(part.id + "#preview")
                            }
                        }
                    }
                    }
                }
                .padding(2).background(highlighted ? VesperTheme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
                if !user { Spacer(minLength: 42) }
            }
        }
    }
    private func reaction(_ part: JSONValue) -> String {
        ChatReactions.emoji(part, in: sourceMessages.isEmpty ? [message] : sourceMessages)
    }
    private func reactionBadge(_ part: JSONValue) -> ChatReactionBadge {
        ChatReactionBadge(editable: !ChatPresentation.isUser(part), emoji: reaction(part), edit: { reactionTarget = part })
    }
    private func actions(_ part: JSONValue) -> [ChatMessageAction] {
        guard part["status"].string != "streaming" else { return [] }
        let saved = ChatFavorites.existing(part.id, conversationID: conversationID, in: store) != nil
        let attachments = part["metadata"]["attachments"].array
        let downloadActions: [ChatMessageAction] = attachments.isEmpty ? [] : [
            ChatMessageAction(title: downloader.downloading ? "下载中" : "下载", icon: "arrow.down.to.line", run: {
                Task { await downloader.download(attachments) }
            })
        ]
        let reactionActions: [ChatMessageAction] = ChatPresentation.isUser(part) ? [] : ChatReactions.quick.map { emoji in
            let selected = reaction(part) == emoji
            return ChatMessageAction(title: selected ? "取消 \(emoji)" : "回应 \(emoji)", icon: "face.smiling",
                run: { Task { await chat.react(to: part, emoji: selected ? "" : emoji) } }, emoji: emoji, selected: selected)
        } + [ChatMessageAction(title: "表情", icon: "face.smiling", run: { reactionTarget = part })]
        return reactionActions + [
            ChatMessageAction(title: "复制", icon: "doc.on.doc", run: { copy(part) }),
            ChatMessageAction(title: saved ? "取消收藏" : "收藏", icon: saved ? "bookmark.fill" : "bookmark", run: { onPartFavorite(part) }),
            ChatMessageAction(title: "引用", icon: "arrowshape.turn.up.left", run: { onReply(part) })
        ] + downloadActions + (busy || saving ? [] : [ChatMessageAction(title: "删除", icon: "trash", run: { onPartDelete(part) })])
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
                            .modifier(reactionBadge(album))
                            .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
                    }
                } else if attachment["type"].string.hasPrefix("video/"), let url = URL(string: attachment["url"].string), url.scheme == "https" {
                    ChatAttachmentPreviewButton(url: url, name: attachment["name"].string) { ChatVideoCard(attachment: attachment) }
                        .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                        .modifier(reactionBadge(part))
                } else if attachment["type"].string.hasPrefix("audio/") {
                    VoiceMessageBar(attachment: attachment, alignment: user ? .trailing : .leading, messageID: part.id, messageActions: { actions(part) }, onTranscript: { text in Task { await chat.saveVoiceTranscript(messageID: item["metadata"]["sourceMessageId"].string.isEmpty ? item.id : item["metadata"]["sourceMessageId"].string, attachmentIndex: item["metadata"]["batchAttachmentIndices"].array.isEmpty ? index : Int(item["metadata"]["batchAttachmentIndices"].array[index].number), text: text) } },
                                    onTranslation: { source, text in Task { await chat.saveVoiceTranslation(messageID: item["metadata"]["sourceMessageId"].string.isEmpty ? item.id : item["metadata"]["sourceMessageId"].string, attachmentIndex: item["metadata"]["batchAttachmentIndices"].array.isEmpty ? index : Int(item["metadata"]["batchAttachmentIndices"].array[index].number), source: source, text: text) } })
                        .modifier(reactionBadge(part))
                } else if let url = URL(string: attachment["url"].string), url.scheme == "https" {
                    ChatAttachmentPreviewButton(url: url, name: attachment["name"].string) { ChatFileCard(attachment: attachment) }
                        .modifier(ChatLongPress(id: part.id, actions: { actions(part) }))
                        .modifier(reactionBadge(part))
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
                }.modifier(ChatLongPress(id: part.id, actions: { actions(part) })).modifier(reactionBadge(part)).id(part.id)
            }
        }
    }
}

private enum ChatScreenshotExport {
    @MainActor static func render(bubbles: [ChatScreenshotBubble]) async throws -> UIImage {
        var images: [String: UIImage] = [:]
        let urls = Set(bubbles.flatMap { bubble -> [String] in
            if case .photos(let photos) = bubble.content { return photos.compactMap { $0["url"].string } }
            return []
        })
        for value in urls where !value.isEmpty {
            guard let url = URL(string: value), ChatWebURL.accepts(url) else { continue }
            if let image = try? await ChatImageProcessing.remotePreview(url, maxPixels: 960) { images[value] = image }
        }
        let renderer = ImageRenderer(content: ChatScreenshotCanvas(bubbles: bubbles, images: images))
        renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
        renderer.scale = 2
        guard let image = renderer.uiImage, image.size.height > 0, image.size.height * image.scale <= 16_000 else {
            throw ServiceError(message: "截图内容太长，请少选几个气泡后重试。")
        }
        return image
    }
}

private struct ChatScreenshotCanvas: View {
    let bubbles: [ChatScreenshotBubble]
    let images: [String: UIImage]
    @AppStorage("vesperPalette") private var palette = "blue"
    @AppStorage(ChatBubbleAppearance.outgoingKey) private var outgoingBubbleColor = ChatBubbleAppearance.automatic
    @AppStorage(ChatBubbleAppearance.incomingKey) private var incomingBubbleColor = ChatBubbleAppearance.automatic
    private var ink: Color { palette == "black" ? .white : Color(red: 0.12, green: 0.14, blue: 0.17) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bubbles) { bubble in
                HStack(spacing: 0) {
                    if bubble.user { Spacer(minLength: 42) }
                    bubbleContent(bubble)
                    if !bubble.user { Spacer(minLength: 42) }
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 22)
            .frame(width: 390)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    WallpaperArtwork(palette: palette)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .overlay(palette == "black" ? Color.black.opacity(0.22) : Color.white.opacity(0.28))
                }
            }
    }
    @ViewBuilder private func bubbleContent(_ bubble: ChatScreenshotBubble) -> some View {
        switch bubble.content {
        case .photos(let photos):
            VStack(alignment: .leading, spacing: 5) {
                if photos.count > 1 {
                    Label("\(photos.count) Photos", systemImage: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(VesperTheme.accent)
                }
                ForEach(Array(photos.enumerated()), id: \.offset) { _, photo in
                    if let image = images[photo["url"].string] {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 270, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        Label("照片暂不可用", systemImage: "photo")
                            .font(.system(size: 13)).frame(width: 220, height: 130)
                            .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        case .attachment(let attachment):
            Label(attachment["name"].string.isEmpty ? "附件" : attachment["name"].string,
                  systemImage: attachment["type"].string.hasPrefix("audio/") ? "waveform" : "doc")
                .font(.system(size: 13)).foregroundStyle(ink)
                .padding(12).background(bubbleColor(bubble.user), in: RoundedRectangle(cornerRadius: 15))
        case .text(let text):
            Text(ChatMarkdownText.render(text))
                .font(.system(size: 15)).lineSpacing(2).foregroundStyle(ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(bubbleColor(bubble.user), in: RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: 312, alignment: bubble.user ? .trailing : .leading)
        case .card(let symbol, let title):
            Label(title, systemImage: symbol)
                .font(.system(size: 13)).foregroundStyle(ink)
                .padding(12).background(bubbleColor(bubble.user), in: RoundedRectangle(cornerRadius: 15))
        case .poke(let text):
            Text(text).font(.system(size: 13)).foregroundStyle(ink)
                .padding(12).background(bubbleColor(bubble.user), in: RoundedRectangle(cornerRadius: 15))
        }
    }
    private func bubbleColor(_ user: Bool) -> Color {
        if let chosen = ChatBubbleAppearance.color(user ? outgoingBubbleColor : incomingBubbleColor) {
            return chosen.opacity(0.42)
        }
        if palette == "black" { return user ? Color.white.opacity(0.24) : Color.white.opacity(0.13) }
        return user ? Color(red: 0.75, green: 0.86, blue: 0.92).opacity(0.9) : Color.white.opacity(0.82)
    }
}

private struct ChatScreenshotPreview: View {
    enum Destination { case system, vesper }
    let image: UIImage
    let api: APIClient
    let onSaved: (Destination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: 390).frame(maxWidth: .infinity).padding(16)
            }.background(Color(white: 0.94))
                .navigationTitle("气泡截图").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 10) {
                        Button { Task { await saveToSystem() } } label: {
                            Label("保存到系统相册", systemImage: "photo.on.rectangle.angled")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(minHeight: 44)
                                .background(Color.black, in: Capsule())
                        }.buttonStyle(.plain)
                        Button { Task { await saveToVesper() } } label: {
                            Label("存入 Vesper 相册", systemImage: "square.stack")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity).frame(minHeight: 44)
                                .background(Color.black, in: Capsule())
                        }.buttonStyle(.plain)
                        if saving { ProgressView() }
                    }.disabled(saving)
                        .padding(16).background(.regularMaterial)
                }
        }
        .alert("保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }
    @MainActor private func saveToSystem() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            error = "请在系统设置中允许 Vesper 添加照片。"; return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            onSaved(.system)
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func saveToVesper() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            guard let data = image.jpegData(compressionQuality: 0.88) else {
                throw ServiceError(message: "截图无法编码。")
            }
            let upload = try await api.uploadImage(data, name: "chat-\(UUID().uuidString).jpg")
            let response = try await api.request("/api/photos", method: "POST", body: .object([
                "key": upload["key"], "category": .string("聊天截图"),
                "caption": .string("聊天截图")
            ]))
            guard !response["photo"].id.isEmpty, response["photo"]["key"] == upload["key"] else {
                throw ServiceError(message: "服务没有确认截图已入相册。")
            }
            onSaved(.vesper)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChatHeaderMenu: View {
    @Binding var expanded: Bool
    let onTerminal: () -> Void
    let onScreenShare: () -> Void
    let onSelectMessages: () -> Void
    var showsVPSDisplay = false
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var store: AppStore
    @Namespace private var menuGlass
    @AppStorage("glassStyle") private var glassStyle = VesperGlassStyle.liquid.rawValue
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("navigationStyle") private var navigationStyle = "vesper"
    @ViewBuilder var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), liquidMenu {
            GlassEffectContainer(spacing: 0) { menuAnchor }
        } else { menuAnchor }
        #else
        menuAnchor
        #endif
    }
    private var liquidMenu: Bool {
        glassStyle != VesperGlassStyle.classic.rawValue && !reduceTransparency
    }
    private var menuAnchor: some View {
        ZStack(alignment: .topTrailing) {
            if expanded {
                Color.clear.frame(width: 44, height: 44)
            } else {
                Button { withAnimation(.spring(response: 0.52, dampingFraction: 0.78)) { expanded = true } } label: {
                    moreButtonLabel
                }
                .buttonStyle(.plain).foregroundStyle(VesperTheme.ink)
                    .accessibilityLabel("More chat options")
                    .accessibilityIdentifier("chat-header-more")
            }
        }
        .overlay(alignment: .topTrailing) {
            if expanded {
                menuContent
                    .transition(liquidMenu ? .opacity : .scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .accessibilityAction(.escape) { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expanded = false } }
    }
    @ViewBuilder private var moreButtonLabel: some View {
        let icon = Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
            .frame(width: 44, height: 44)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), liquidMenu {
            icon.glassEffect(.clear.interactive(), in: Circle())
                .glassEffectID("chat-header-menu", in: menuGlass)
                .glassEffectTransition(.matchedGeometry)
        } else { icon.vesperGlass(in: Circle(), interactive: true) }
        #else
        icon.vesperGlass(in: Circle(), interactive: true)
        #endif
    }
    @ViewBuilder private var menuContent: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), liquidMenu {
            menuRows
                .glassEffect(.regular, in: shape)
                .glassEffectID("chat-header-menu", in: menuGlass)
                .glassEffectTransition(.matchedGeometry)
                .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
        } else { classicMenuContent(shape: shape) }
        #else
        classicMenuContent(shape: shape)
        #endif
    }
    private func classicMenuContent(shape: RoundedRectangle) -> some View {
        menuRows
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
    }
    @ViewBuilder private var menuRows: some View {
                VStack(alignment: .leading, spacing: 0) {
                    Text(chat.conversations.first(where: { $0.id == chat.conversationID })?["title"].string ?? store.agentDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VesperTheme.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                    Divider().padding(.horizontal, 12)
                    menuRow("Screenshot", symbol: "checkmark.circle", action: onSelectMessages)
                    menuRow(showsVPSDisplay ? "View VPS" : "Terminal",
                            symbol: showsVPSDisplay ? "display" : "terminal", action: onTerminal)
                    Divider().padding(.horizontal, 12).padding(.vertical, 6)
                    menuRow("Share screen", symbol: "rectangle.on.rectangle", disabled: !screenSharingAllowed,
                            action: onScreenShare)
                        .accessibilityIdentifier("chat-share-screen")
                    #if !targetEnvironment(macCatalyst)
                    TimelineView(.periodic(from: .now, by: 3)) { _ in
                        if BroadcastAccess.isSharing() {
                            menuRow("Show \(store.agentDisplayName) this screen", symbol: "eye") {
                                try? BroadcastAccess.requestLookNow()
                            }
                        }
                    }
                    #endif
                    Divider().padding(.horizontal, 12).padding(.vertical, 6)
                    Text("REPLY MODE").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(VesperTheme.muted)
                        .padding(.horizontal, 14).padding(.top, 5).padding(.bottom, 3)
                    ForEach(ChatReplyMode.allCases, id: \.rawValue) { mode in
                        menuRow(mode == .immediate ? "Instant reply" : "Later reply", symbol: mode == .immediate ? "bolt" : "text.bubble",
                                selected: chat.replyMode == mode, disabled: chat.sending || chat.callActive) {
                            chat.replyMode = mode
                        }
                            .accessibilityValue(chat.replyMode == mode ? "Selected" : "")
                    }
                    Divider().padding(.horizontal, 12).padding(.vertical, 6)
                    if VesperLayout.usesSidebar {
                        MacAppearanceButton(title: "Appearance")
                            .font(.system(size: 16, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .padding(.horizontal, 14)
                    } else {
                        menuRow(navigationStyle == "native" ? "Switch to Vesper" : "Switch to Apple Native",
                                symbol: navigationStyle == "native" ? "sidebar.left" : "rectangle.bottomthird.inset.filled") {
                            navigationStyle = navigationStyle == "native" ? "vesper" : "native"
                        }
                    }
                }.padding(8).frame(width: 248).foregroundStyle(VesperTheme.ink)
    }
    private func menuRow(_ title: String, symbol: String, selected: Bool = false,
                         disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { expanded = false }; action() } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 19, weight: .regular))
                    .frame(width: 24)
                Text(title).font(.system(size: 15, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)) }
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 14).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .accessibilityLabel(title)
    }
    private var screenSharingAllowed: Bool {
        #if targetEnvironment(macCatalyst)
        !store.token.isEmpty && !chat.conversationID.isEmpty
        #else
        store.activeBackend == .vps && !store.token.isEmpty && !chat.conversationID.isEmpty
        #endif
    }
}

#if !targetEnvironment(macCatalyst)
private struct ChatScreenShareSheet: View {
    let conversationID: String
    let conversationTitle: String
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pip = ScreenSharePiP.shared
    @State private var ready = false
    @State private var error = ""
    @State private var captureInterval = 10.0

    var body: some View {
        NavigationStack {
            ZStack {
                Background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 14) {
                                    Image(systemName: "rectangle.on.rectangle")
                                        .font(.system(size: 23, weight: .medium))
                                        .frame(width: 34)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("整个屏幕").font(.system(size: 17, weight: .semibold))
                                        Text("一起看 · \(conversationTitle)")
                                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                    if ready {
                                        BroadcastPicker().frame(width: 52, height: 52)
                                            .accessibilityLabel("开始或管理屏幕分享")
                                    } else {
                                        Image(systemName: "record.circle")
                                            .font(.system(size: 30)).frame(width: 52, height: 52)
                                            .foregroundStyle(VesperTheme.muted)
                                    }
                                }
                                Divider()
                                TimelineView(.periodic(from: .now, by: 3)) { _ in
                                    let status = BroadcastAccess.observation()["status"] as? String ?? ""
                                    let sharing = BroadcastAccess.isSharing()
                                    HStack(spacing: 8) {
                                        Circle().fill(sharing ? Color.green : VesperTheme.muted.opacity(0.6))
                                            .frame(width: 7, height: 7)
                                        Text(sharing ? (status.hasPrefix("Screen connection failed") ? "正在分享 · 连接重试" : "正在分享") : status == "Screen sharing paused" ? "已暂停" : status == "Screen sharing ended" ? "分享已结束" : "尚未开始")
                                        Spacer()
                                    }.font(.subheadline).foregroundStyle(VesperTheme.muted)
                                }
                                Text("点右侧录屏按钮并选择 Vesper；结束时使用系统录屏控件。")
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 13) {
                                Label("画面采样", systemImage: "eye")
                                    .font(.system(size: 17, weight: .semibold))
                                Picker("看画面的间隔", selection: $captureInterval) {
                                    ForEach([5.0, 10.0, 20.0, 30.0], id: \.self) { seconds in
                                        Text("\(Int(seconds)) 秒").tag(seconds)
                                    }
                                }.pickerStyle(.segmented)
                                Text("按此间隔看画面；回复尚未结束时会等这一轮完成。")
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                                Button {
                                    do { try BroadcastAccess.requestLookNow() }
                                    catch { self.error = error.localizedDescription }
                                } label: {
                                    Label("让 \(store.agentDisplayName) 看这一幕", systemImage: "eye")
                                        .font(.system(size: 15, weight: .semibold))
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                        .vesperGlass(in: Capsule(), interactive: true)
                                }.buttonStyle(.plain)
                            }
                        }
                        if ready && UIDevice.current.userInterfaceIdiom == .phone {
                            GlassCard {
                              VStack(alignment: .leading, spacing: 13) {
                                HStack {
                                    Label("悬浮小窗", systemImage: "pip")
                                        .font(.system(size: 17, weight: .semibold))
                                    Spacer()
                                    if pip.active { Text("已开启").font(.caption).foregroundStyle(VesperTheme.muted) }
                                }
                                ScreenSharePiPSource(manager: pip)
                                    .frame(maxWidth: 320).frame(height: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                                Picker("小窗外观", selection: Binding(
                                    get: { pip.style }, set: { pip.setStyle($0) })) {
                                    ForEach(ScreenShareCardStyle.allCases, id: \.self) { style in
                                        Text(style.title).tag(style)
                                    }
                                }.pickerStyle(.segmented)
                                Button {
                                    if pip.active { pip.stop() } else { pip.start() }
                                } label: {
                                    Label(pip.active ? "关闭小窗" : "开启悬浮小窗",
                                          systemImage: pip.active ? "pip.exit" : "pip.enter")
                                        .frame(maxWidth: .infinity, minHeight: 46)
                                        .vesperGlass(in: Capsule(), interactive: true)
                                }.buttonStyle(.plain)
                                    .disabled(!ScreenSharePiP.supported)
                                Text("先开始屏幕分享，再开启小窗；回到聊天后可再次打开。")
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                                if let pipError = pip.error {
                                    Text(pipError).font(.caption).foregroundStyle(.red)
                                }
                              }.frame(maxWidth: 360, alignment: .leading)
                            }
                        }
                        if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(18).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("分享屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .foregroundStyle(VesperTheme.ink)
        .onAppear { captureInterval = BroadcastAccess.captureInterval() }
        .onChange(of: captureInterval) { _, value in
            do { try BroadcastAccess.setCaptureInterval(value) }
            catch { self.error = error.localizedDescription }
        }
        .task(id: store.historyURL + "\n" + store.token + "\n" + conversationID + "\n" + chat.model) {
            ready = false; error = ""
            guard store.activeBackend == .vps, !store.token.isEmpty, !conversationID.isEmpty else {
                error = "请先打开已连接 VPS 的聊天。"; return
            }
            do {
                try BroadcastAccess.save(historyURL: store.historyURL, token: store.token,
                    conversationID: conversationID,
                    instructions: store.resolvedAgentInstructions(UserDefaults.standard.string(forKey: "nativeInstructions"))
                        + ChatOrganization.instructions(api: store.api, conversation: conversationID),
                    name: store.agentDisplayName, userName: store.document("profile")["userName"].string,
                    model: chat.model)
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: store.baseURL + "\n" + store.document("profile")["agentAvatar"].string + "\n" + store.agentDisplayName) {
            let source = store.document("profile")["agentAvatar"].string
            let avatar = await ChatAvatarImageCache.shared.image(for: ChatAvatarSource(source: source, baseURL: store.baseURL))
            guard !Task.isCancelled else { return }
            pip.setIdentity(name: store.agentDisplayName, avatar: avatar)
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
@MainActor private final class MacChatScreenShare: NSObject, ObservableObject, SCContentSharingPickerObserver {
    static let shared = MacChatScreenShare()
    static let intervalOptions: [Double] = [5, 10, 20, 30]
    private static let intervalKey = "macScreenShareCaptureInterval"
    @Published private(set) var active = false
    @Published private(set) var choosing = false
    @Published private(set) var status = "尚未开始"
    @Published private(set) var captureInterval = 10.0

    private var filter: SCContentFilter?
    private var work: Task<Void, Never>?
    private weak var chat: ChatSession?
    private weak var store: AppStore?
    private var conversationID = ""
    private var backend: VesperBackend = .vps
    private var oneShot = false

    override private init() {
        super.init()
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        captureInterval = Self.intervalOptions.contains(saved) ? saved : 10
        SCContentSharingPicker.shared.add(self)
    }

    func setCaptureInterval(_ seconds: Double) {
        guard Self.intervalOptions.contains(seconds) else { return }
        captureInterval = seconds
        UserDefaults.standard.set(seconds, forKey: Self.intervalKey)
    }

    func choose(chat: ChatSession, store: AppStore, conversationID: String, once: Bool = false) {
        guard !conversationID.isEmpty, !store.token.isEmpty else { status = "请先连接聊天。"; return }
        self.chat = chat; self.store = store; self.conversationID = conversationID
        backend = store.activeBackend
        oneShot = once
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        picker.defaultConfiguration = configuration
        picker.isActive = true
        choosing = true
        picker.present(using: .display)
    }

    func stop() {
        active = false; choosing = false; filter = nil
        oneShot = false
        work?.cancel(); work = nil
        SCContentSharingPicker.shared.isActive = false
        status = "分享已结束"
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.choosing = false; if !self.active { picker.isActive = false } }
    }
    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.begin(filter: filter) }
    }
    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.choosing = false; self.status = error.localizedDescription }
    }

    private func begin(filter: SCContentFilter) {
        guard let chat, let store else { status = "聊天已关闭，请重新选择。"; return }
        work?.cancel()
        self.filter = filter
        choosing = false; active = true; status = "正在分享"
        let room = conversationID, selectedBackend = backend
        if oneShot {
            status = "正在截取一张画面"
            work = Task { [weak self, weak chat, weak store] in
                guard let self, let chat, let store else { return }
                do {
                    let frame = try await self.snapshot(filter: filter)
                    guard self.active, !Task.isCancelled else { return }
                    for _ in 0..<180 {
                        guard self.active, chat.conversationID == room,
                              store.activeBackend == selectedBackend else {
                            self.stop(); return
                        }
                        if !chat.busy && !chat.sending { break }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    guard self.active, !chat.busy, !chat.sending else {
                        self.stop(); self.status = "当前回复尚未结束，截图没有发出"; return
                    }
                    let sent = await chat.send(ChatScreenContext.oneShotPrompt,
                                               images: [frame], screenContext: true)
                    self.stop()
                    self.status = sent ? "已分享一张画面" : "截图没有发出，请重试"
                } catch is CancellationError { return }
                catch { self.stop(); self.status = "截图失败：" + error.localizedDescription }
            }
            return
        }
        work = Task { [weak self, weak chat, weak store] in
            guard let self, let chat, let store else { return }
            var lastSampleAt = Date.distantPast
            while self.active && !Task.isCancelled {
                guard chat.conversationID == room, store.activeBackend == selectedBackend else {
                    self.stop(); self.status = "聊天已切换，分享已停止"; return
                }
                if !chat.busy && !chat.sending && Date().timeIntervalSince(lastSampleAt) >= self.captureInterval {
                    do {
                        let frame = try await self.snapshot(filter: filter)
                        guard self.active && !Task.isCancelled else { return }
                        lastSampleAt = Date()
                        _ = await chat.send(ChatScreenContext.macPrompt, images: [frame], screenContext: true)
                        if self.active { self.status = "正在分享" }
                    } catch is CancellationError { return }
                    catch { self.stop(); self.status = "屏幕捕捉失败：" + error.localizedDescription; return }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func snapshot(filter: SCContentFilter) async throws -> Data {
        let configuration = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = min(1, 1000 / max(rect.width, rect.height, 1))
        configuration.width = max(1, Int(rect.width * scale))
        configuration.height = max(1, Int(rect.height * scale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.65) else {
            throw ServiceError(message: "无法读取屏幕画面。")
        }
        return data
    }
}

private struct MacChatScreenShareSheet: View {
    let conversationID: String
    let conversationTitle: String
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sharing = MacChatScreenShare.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Background()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("分享 Mac 屏幕").font(.headline)
                                Text("一起看 · \(conversationTitle)")
                                    .font(.subheadline).foregroundStyle(VesperTheme.muted)
                                Button {
                                    if sharing.active { sharing.stop() }
                                    else { sharing.choose(chat: chat, store: store, conversationID: conversationID) }
                                } label: {
                                    Label(sharing.active ? "停止分享" : sharing.choosing ? "选择屏幕中…" : "选择要分享的屏幕",
                                          systemImage: sharing.active ? "stop.circle.fill" : "rectangle.on.rectangle")
                                        .frame(maxWidth: .infinity, minHeight: 48)
                                        .vesperGlass(in: Capsule(), interactive: true)
                                }.buttonStyle(.plain).disabled(sharing.choosing)
                                Text(sharing.status).font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 13) {
                                Label("画面采样", systemImage: "eye")
                                    .font(.system(size: 17, weight: .semibold))
                                Picker("看画面的间隔", selection: Binding(
                                    get: { sharing.captureInterval },
                                    set: { sharing.setCaptureInterval($0) })) {
                                    ForEach(MacChatScreenShare.intervalOptions, id: \.self) { seconds in
                                        Text("\(Int(seconds)) 秒").tag(seconds)
                                    }
                                }.pickerStyle(.segmented)
                                Text("按此间隔看画面；回复尚未结束时会等这一轮完成。")
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                            }
                        }
                        Text("有话想说时会回复到当前聊天。选定后可切换到其他 Mac 应用；关闭这个面板不会停止分享。")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("分享屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.foregroundStyle(VesperTheme.ink)
    }
}
#endif

private struct ChatHeaderButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.frame(width: 36, height: 44).opacity(configuration.isPressed ? 0.5 : 1) }
}

// Keep persisted records intact; classify only their presentation, never by message text.
// Retained by ChatSession until the message array changes. Scroll geometry,
// playback ticks and composer state must not re-sort/re-group the transcript.
final class ChatPresentationSnapshot {
    let rows: [ChatPresentation.Row]
    let lastReplyID: String?
    private let headingsByTurn: [String: String]
    func liveHeadingID(turnID: String) -> String? { headingsByTurn[turnID] }
    func rowID(forMessageID id: String) -> String {
        rows.first { $0.messages.contains { $0.id == id } }?.id ?? id
    }
    init(_ messages: [JSONValue]) {
        rows = ChatPresentation.displayRows(messages)
        var headings: [String: String] = [:]
        for row in rows {
            for message in row.messages where !ChatPresentation.isUser(message) && !ChatPresentation.isLetterReminder(message) && ChatPokeNotice.target(message) == nil {
                let turn = message["metadata"]["turnId"].string
                if !turn.isEmpty { headings[turn] = row.id }
            }
        }
        headingsByTurn = headings
        lastReplyID = rows.last { !$0.activity && !$0.messages.contains(where: ChatPresentation.isUser) && !$0.messages.contains(where: ChatPresentation.isLetterReminder) && !$0.messages.contains(where: { ChatPokeNotice.target($0) != nil }) }?.id
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
                && meta["userInput"] == .null && ChatPokeNotice.target($0) == nil
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
        let ordered = ChatTranscript.ordered(input.flatMap(ChatScreenContext.visibleRecords))
        let hiddenCallTurns = Set(ordered.filter {
            $0["metadata"]["privateCallInvitation"].bool || $0["metadata"]["callOnly"].bool
        }.compactMap(turnKey))
        let messages = ordered.filter {
            !isWakeActivity($0) && !$0["metadata"]["privateCallInvitation"].bool
                && !$0["metadata"]["callOnly"].bool
                && ($0["metadata"]["call"] != .null
                    || !(turnKey($0).map { hiddenCallTurns.contains($0) } ?? false))
        }
        // Index turn ownership once. Re-scanning the complete history for every
        // tool row was quadratic, especially in chats with many tool calls.
        var firstReplyByTurn: [TurnKey: Int] = [:]
        var nextReply = Array<Int?>(repeating: nil, count: messages.count)
        var nextLegacyReply = nextReply
        var next: Int?, nextLegacy: Int?
        for index in messages.indices.reversed() {
            nextReply[index] = next; nextLegacyReply[index] = nextLegacy
            if isUser(messages[index]) { next = nil; nextLegacy = nil }
            else if !isActivity(messages[index]) && !isLetterReminder(messages[index]) && ChatPokeNotice.target(messages[index]) == nil {
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
            if isLetterReminder(message) || ChatPokeNotice.target(message) != nil { continue }
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

private enum ChatProcessStatus {
    static func label(_ status: String) -> String {
        switch status.lowercased() {
        case "completed", "succeeded", "success": return "Complete"
        case "failed", "error", "declined", "interrupted", "cancelled": return "Fail"
        case "running", "inprogress", "started": return "Running"
        default: return "Pending"
        }
    }
    static func symbol(_ status: String) -> String {
        switch status.lowercased() {
        case "completed", "succeeded", "success": return "checkmark.circle.fill"
        case "failed", "error", "declined", "interrupted", "cancelled": return "xmark.circle.fill"
        case "running", "inprogress", "started": return "clock.fill"
        default: return "circle"
        }
    }
    static func color(_ status: String) -> Color {
        VesperTheme.muted
    }
}

private struct ChatProcessStep<Content: View>: View {
    let status: String
    let isLast: Bool
    let isTool: Bool
    let content: Content
    init(status: String, isLast: Bool, isTool: Bool = false, @ViewBuilder content: () -> Content) {
        self.status = status
        self.isLast = isLast
        self.isTool = isTool
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isTool ? "wrench" : ChatProcessStatus.symbol(status))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ChatProcessStatus.color(status))
                .frame(width: 18, height: 18)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, isLast ? 0 : 13)
        .background(alignment: .topLeading) {
            if !isLast {
                GeometryReader { geometry in
                    Rectangle().fill(VesperTheme.muted.opacity(0.35))
                        .frame(width: 1, height: max(0, geometry.size.height - 21))
                        .offset(x: 8.5, y: 21)
                }.allowsHitTesting(false)
            }
        }
    }
}

private struct ToolCallRow: View {
    let tool: JSONValue
    @State private var showingDetails = false
    @State private var expanded = false
    private var title: String { tool["title"].string.isEmpty ? "Tool call" : tool["title"].string }
    private var output: String { tool["output"].string.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasOutput: Bool { !output.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { if hasOutput { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } } label: {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(VesperTheme.muted).lineLimit(2)
                    Spacer(minLength: 8)
                    if tool["durationMs"] != .null {
                        Text(String(format: "%.1fs", tool["durationMs"].number / 1000))
                            .font(.caption2.monospacedDigit()).foregroundStyle(VesperTheme.muted)
                    }
                    Text(ChatProcessStatus.label(tool["status"].string))
                        .font(.caption2.weight(.medium)).foregroundStyle(ChatProcessStatus.color(tool["status"].string))
                    if hasOutput { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(VesperTheme.muted) }
                }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(title + ", " + ChatProcessStatus.label(tool["status"].string) + (hasOutput ? ", details" : ""))
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text(String(output.prefix(1_400)))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(VesperTheme.muted)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if output.count > 1_400 {
                    Button("View full log") { showingDetails = true }
                        .font(.caption.weight(.medium)).buttonStyle(.plain)
                }
                if tool["truncated"].bool { Text("Saved result is partial.").font(.caption2).foregroundStyle(VesperTheme.muted) }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label(tool["status"].string.capitalized, systemImage: "wrench")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted)
                        if hasOutput {
                            Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
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
    private var status: String { running ? "Running" : failed > 0 ? "Fail" : finished == records.count ? "Complete" : "Pending" }
    private var statusIcon: String { running ? "terminal" : failed > 0 ? "exclamationmark.circle" : finished == records.count ? "checkmark.circle" : "clock" }
    private var color: Color { VesperTheme.muted }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { details = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(red: 0.08, green: 0.09, blue: 0.12), in: RoundedRectangle(cornerRadius: 9))
                    Text("\(records.count) \(records.count == 1 ? "operation" : "operations")")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(VesperTheme.muted)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("View all \(records.count) terminal operations, \(status)")
            HStack {
                Label("Terminal", systemImage: "terminal")
                    .font(.caption.weight(.medium)).foregroundStyle(VesperTheme.muted)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .vesperMaterial(.thinMaterial, in: Capsule())
                Spacer(minLength: 8)
                Text(status).font(.caption2.weight(.medium)).foregroundStyle(VesperTheme.muted)
            }
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
            Button { details = true } label: { Label("View all", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 12)).foregroundStyle(VesperTheme.muted).frame(minHeight: 36) }.buttonStyle(.plain)
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
    var tokenUsage: JSONValue = .null
    @State private var expanded = false
    private var terminal: [JSONValue] { ChatTerminalRecords.entries(activities) }
    private var otherExecutions: [JSONValue] {
        activities.filter { $0["metadata"]["execution"] != .null && ChatTerminalRecords.entries([$0]).isEmpty }
    }
    private var toolEvents: [String] {
        liveEvents.isEmpty ? message["metadata"]["toolEvents"].array.map { $0.string } : liveEvents
    }
    private var toolCards: [JSONValue] { ToolActivityRecords.cards(toolEvents) }
    private var thoughtTexts: [String] {
        var seen = Set<String>()
        let summary = message["metadata"]["thoughtSummary"].string
        let activityTexts = activities.filter { $0["metadata"]["execution"] == .null && $0["metadata"]["userInput"] == .null }
            .map { item in
                let thought = item["metadata"]["thoughtSummary"].string
                return thought.isEmpty ? item["content"].string : thought
            }
        return ([summary.replacingOccurrences(of: "****", with: "**\n**")]
                + activityTexts.filter { !summary.contains($0) }).compactMap { value in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || !seen.insert(text).inserted ? nil : text
        }
    }
    private var showsThinking: Bool { !thoughtTexts.isEmpty || isLive || message["status"].string == "streaming" }
    private var stepCount: Int {
        (showsThinking ? 1 : 0) + otherExecutions.count + toolCards.count
    }
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
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("时间、思考摘要和工具调用").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if !terminal.isEmpty {
                TerminalOperationGroup(records: terminal, live: isLive)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    if showsThinking {
                        ChatProcessStep(status: isLive ? "running" : "completed", isLast: stepCount == 1) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Thinking summary").font(.caption.weight(.medium))
                                ForEach(Array(thoughtTexts.enumerated()), id: \.offset) { _, text in
                                    ChatMarkdownText(content: text).font(.system(size: 13))
                                }
                                if thoughtTexts.isEmpty { Text("Thinking…").font(.system(size: 13)) }
                            }.foregroundStyle(VesperTheme.muted).padding(.vertical, 2)
                        }
                    }
                    ForEach(Array(otherExecutions.enumerated()), id: \.offset) { index, item in
                        ChatProcessStep(status: item["metadata"]["execution"]["status"].string,
                                        isLast: index == otherExecutions.count - 1 && toolCards.isEmpty, isTool: true) {
                            ToolCallRow(tool: item["metadata"]["execution"])
                        }
                    }
                    ForEach(Array(toolCards.enumerated()), id: \.offset) { index, card in
                        ChatProcessStep(status: card["status"].string, isLast: index == toolCards.count - 1, isTool: true) {
                            ToolCallRow(tool: card)
                        }
                    }
                    ChatTokenUsageButton(value: tokenUsage).padding(.vertical, 8)
                }.padding(.leading, 2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatTokenUsageButton: View {
    let value: JSONValue
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            Label("Tokens", systemImage: "number")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .vesperMaterial(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(VesperTheme.muted)
        .accessibilityLabel("Token usage").accessibilityIdentifier("chat.token-usage.button")
        .popover(isPresented: $showing, attachmentAnchor: .rect(.bounds)) {
            ChatTokenUsageDetails(value: value, close: { showing = false })
                .padding(16).frame(width: 310)
                .preferredColorScheme(VesperTheme.palette == .black ? .dark : .light)
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct ChatTokenUsageDetails: View {
    let value: JSONValue
    var title = "Turn usage"
    var close: (() -> Void)? = nil
    private var usage: ChatTokenUsage? { ChatTokenUsage(value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage {
                HStack {
                    Label(usage.scope == "latestRequest" ? "Latest request" : title + (value["complete"].bool ? "" : " · so far"), systemImage: "number")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(usage.total.formatted()) tokens").font(.caption.weight(.semibold)).monospacedDigit()
                    closeButton
                }
                row("Input", usage.input.formatted())
                row("Cached input", usage.cached?.formatted() ?? "Unavailable")
                if let cached = usage.cached { row("Uncached input", (usage.input - cached).formatted()) }
                row("Output", usage.output.formatted())
                row("Reasoning · included in output", usage.reasoning?.formatted() ?? "Unavailable")
                row("Cache hit rate", usage.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(1))) } ?? "Unavailable")
                Text(usage.scope == "latestRequest"
                    ? "Only the latest model request was reported after reconnecting. Earlier tool rounds are unavailable."
                    : "Sum across requests and tool rounds, not the 80k compaction meter. Cache rate = cached input ÷ input.")
                    .font(.caption2).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top) {
                    Text("Token usage was not recorded for this reply.").font(.caption)
                    closeButton
                }
            }
        }.foregroundStyle(VesperTheme.muted)
            .accessibilityElement(children: .contain).accessibilityIdentifier("chat.token-usage")
    }
    @ViewBuilder private var closeButton: some View {
        if let close {
            Button(action: close) { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 24, height: 28) }
                .buttonStyle(.plain).foregroundStyle(VesperTheme.ink).accessibilityLabel("Close token usage")
        }
    }
    private func row(_ label: String, _ count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(count).monospacedDigit()
        }.font(.caption)
    }
}

private struct CallRecordButton: View {
    @EnvironmentObject private var store: AppStore
    let message: JSONValue
    var messageActions: () -> [ChatMessageAction] = { [] }
    @State private var showing = false
    var body: some View {
        Group {
            Label(message["content"].string, systemImage: message["metadata"]["call"]["video"] == .bool(true) ? "video" : "phone")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }.modifier(ChatLongPress(id: message.id, actions: messageActions, onTap: { showing = true }))
        .sheet(isPresented: $showing) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(message["content"].string).font(.headline)
                        if message["metadata"]["call"]["transcript"].array.isEmpty { Text("No conversation was recorded.").foregroundStyle(.secondary) }
                        ForEach(Array(message["metadata"]["call"]["transcript"].array.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(store.personDisplayName(entry["speaker"].string) + " · " + ChatPresentation.time(entry["at"].string)).font(.caption).foregroundStyle(.secondary)
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
    static func receiptIDs(for row: ChatPresentation.Row) -> Set<String> {
        guard let first = row.messages.first, !ChatPresentation.isUser(first) else { return [] }
        return Set((row.messages + row.activities)
            .flatMap { [$0.id, $0["metadata"]["itemId"].string] }
            .filter { !$0.isEmpty })
    }
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

private struct ChatAvatarPatMotion: ViewModifier {
    let trigger: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.phaseAnimator([0.0, -7, 6, -4, 3, 0], trigger: trigger) { view, angle in
            view.rotationEffect(.degrees(reduceMotion ? 0 : angle))
        } animation: { _ in .easeInOut(duration: 0.075) }
            .sensoryFeedback(.impact(weight: .light), trigger: trigger)
    }
}
