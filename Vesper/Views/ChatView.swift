import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    var onMenu: () -> Void = {}
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @EnvironmentObject private var player: MusicPlayer
    @StateObject private var speech = SpeechInput()
    @StateObject private var location = ChatLocation()
    @State private var speechBase = ""
    @State private var avatarRole = "user"
    @State private var avatarPicker = false
    @State private var avatarPhoto: PhotosPickerItem?
    @State private var savingAvatar = false
    @State private var draft = ""
    @State private var history = false
    @State private var historyTab = 0
    @State private var query = ""
    @State private var modelPicker = false
    @State private var drawer = false
    @State private var photoPicker = false
    @State private var cameraPicker = false
    @State private var call = false
    @State private var filePicker = false
    @State private var musicPicker = false
    @State private var locationPicker = false
    @State private var confirmNew = false
    @State private var deleting: JSONValue?
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var files: [ChatFile] = []
    @State private var loadingPhotos = false
    @FocusState private var focused: Bool
    private var chatContent: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
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
                }.scrollDismissesKeyboard(.interactively)
                .task { await Task.yield(); proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) { composer; if drawer { attachmentDrawer.transition(.move(edge: .bottom).combined(with: .opacity)) } }
        }
    }
    private var photoContent: some View {
        chatContent
        .task { chat.configure(store); await chat.openLatestConversation() }
        .onChange(of: focused) { _, value in if value { drawer = false } }
        .onChange(of: speech.text) { _, text in draft = speechBase + (speechBase.isEmpty || text.isEmpty ? "" : " ") + text }
        .onChange(of: speech.error) { _, error in if let error { chat.error = error } }
        .onDisappear { speech.stop() }
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
                    let saved = await store.mutate("profile") { current in
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
    private var header: some View {
        HStack(spacing: 5) {
            Button(action: onMenu) { Image(systemName: "line.3.horizontal") }.accessibilityLabel("Open sidebar")
            Spacer()
            Button { avatarRole = "user"; avatarPicker = true } label: { profileAvatar("user", fallbackName: "Vera") }.accessibilityLabel("Change Vera’s avatar").disabled(savingAvatar)
            Button { avatarRole = "agent"; avatarPicker = true } label: { profileAvatar("agent", fallbackName: "Rowan") }.accessibilityLabel("Change Rowan’s avatar").disabled(savingAvatar)
            Spacer()
            Button { if draft.isEmpty && images.isEmpty && files.isEmpty { newChat() } else { confirmNew = true } } label: { Image(systemName: "plus") }.accessibilityLabel("New chat").disabled(chat.busy || chat.loadingModels)
            Button { openCall() } label: { Image(systemName: "phone") }.accessibilityLabel("Call").disabled(chat.busy)
            Button { focused = false; speech.stop(); history = true; Task { await chat.loadConversations() } } label: { Image(systemName: "archivebox") }.accessibilityLabel("Conversations and favorites")
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
                if !user { AssistantMessageHeading(message: message, activities: activities, liveEvents: !chat.busy && message.id == chat.messages.last(where: { !ChatPresentation.isUser($0) && !ChatPresentation.isActivity($0) })?.id ? chat.events : []) }
                if !message["metadata"]["attachments"].array.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(Array(message["metadata"]["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                        if attachment["type"].string.hasPrefix("image/") { Artwork(url: attachment["url"].string).frame(width: 160, height: 160).clipShape(RoundedRectangle(cornerRadius: 15)) }
                        else if let url = URL(string: attachment["url"].string), url.scheme == "https" { Link(destination: url) { Label(attachment["name"].string, systemImage: "doc").font(.caption).padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                    } } }
                }
                Text(message["content"].string).font(.system(size: 15)).lineSpacing(4).multilineTextAlignment(user ? .trailing : .leading).textSelection(.enabled)
                if message["status"].string == "error" { Text("Send not confirmed").font(.caption).foregroundStyle(.red) }
                if message["status"].string != "streaming" {
                    HStack(spacing: 12) {
                        if user { Text(ChatPresentation.time(message["createdAt"].string)).font(.caption2) }
                        Button { UIPasteboard.general.string = message["content"].string } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy message")
                        Button { Task { await favorite(message) } } label: { Image(systemName: isFavorite(message) ? "bookmark.fill" : "bookmark") }.accessibilityLabel("Favorite message").disabled(store.saving)
                        Button { deleting = message } label: { Image(systemName: "trash") }.accessibilityLabel("Delete message").disabled(chat.busy)
                    }.font(.system(size: 15)).foregroundStyle(VesperTheme.muted).buttonStyle(.plain).padding(.vertical, 4)
                }
            }.frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 20) }
        }
    }
    private var composer: some View {
        VStack(spacing: 4) {
            if !images.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topTrailing) { Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }.disabled(chat.busy) } }
                } } }
            }
            ForEach(files) { file in HStack { Label(file.name, systemImage: "doc").lineLimit(1); Spacer(); Button { files.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark") }.disabled(chat.busy) }.font(.caption) }
            TextField(speech.listening ? "Listening…" : "Write to Rowan…", text: $draft, axis: .vertical).lineLimit(1...5).focused($focused).font(.system(size: 16))
            HStack(spacing: 4) {
                Button { focused = false; speech.stop(); withAnimation(.easeOut(duration: 0.2)) { drawer.toggle() } } label: { Image(systemName: drawer ? "xmark" : "plus").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Attachments").disabled(chat.busy)
                Button { focused = false; modelPicker = true } label: { HStack(spacing: 4) { Text((chat.model.isEmpty ? "Default" : chat.model) + (chat.effort.isEmpty ? "" : " · " + chat.effort.capitalized)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9)) }.font(.system(size: 12)).frame(maxWidth: 160, minHeight: 40, alignment: .leading) }.disabled(chat.busy)
                Spacer()
                Button { focused = false; drawer = false; if speech.listening { speech.stop() } else { player.pause(); speechBase = draft; Task { await speech.start() } } } label: { Image(systemName: speech.listening ? "mic.fill" : "mic").font(.system(size: 20)).frame(width: 40, height: 40) }.accessibilityLabel("Voice input").disabled(chat.busy)
                if chat.busy { Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40) } }
                else { Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40) }.disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty && files.isEmpty) || loadingPhotos || chat.loadingModels).accessibilityLabel("Send") }
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
        }.padding(20).background(.regularMaterial)
    }
    private func drawerItem(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button { drawer = false; action() } label: { VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 26)).frame(width: 58, height: 58).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16)); Text(title).font(.system(size: 12)) }.frame(maxWidth: .infinity) }.buttonStyle(.plain).disabled(chat.busy || loadingPhotos || ((title == "Album" || title == "Camera") && images.count >= 5))
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
            ForEach(store.document("music").array) { track in Button { draft += (draft.isEmpty ? "" : "\n") + "Listen with me: " + track["title"].string + " — " + track["artist"].string + "\n" + track["url"].string; musicPicker = false } label: { Label(track["title"].string, systemImage: "music.note") } }
            if store.document("music").array.isEmpty { Text("Add songs in Music first.") }
        }.navigationTitle("Music").toolbar { Button("Done") { musicPicker = false } } }.presentationDetents([.medium, .large])
    }
    private var historySheet: some View {
        NavigationStack {
            VStack {
                Picker("Collection", selection: $historyTab) { Text("Conversations").tag(0); Text("Favorites").tag(1) }.pickerStyle(.segmented).padding(.horizontal)
                List {
                    if historyTab == 0 {
                        ForEach(chat.conversations.filter { query.isEmpty || $0["title"].string.localizedCaseInsensitiveContains(query) }) { item in Button { Task { await chat.open(item); history = false } } label: { VStack(alignment: .leading) { Text(item["title"].string); Text(ChatPresentation.time(item["updatedAt"].string)).font(.caption).foregroundStyle(.secondary) } }.disabled(chat.busy) }
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
        }.presentationDetents([.large])
    }
    private func isFavorite(_ message: JSONValue) -> Bool { store.document("favorites").array.contains { $0["messageId"].string == message.id } }
    private func favorite(_ message: JSONValue) async {
        if let item = store.document("favorites").array.first(where: { $0["messageId"].string == message.id }) { _ = await store.remove("favorites", id: item.id); return }
        _ = await store.upsert("favorites", item: .object(["id": .string(UUID().uuidString), "folderId": .string("default"), "messageId": .string(message.id), "conversationId": .string(chat.conversationID), "conversationTitle": .string("Conversations"), "content": message["content"], "role": message["role"], "createdAt": message["createdAt"]]))
    }
    private func newChat() { speech.stop(); Task { if await chat.createConversation() { draft = ""; images = []; files = [] } } }
    private func openCall() { speech.stop(); focused = false; drawer = false; call = true }
    private func send() {
        speech.stop(); let sending = draft; let outgoing = images; let outgoingFiles = files; drawer = false
        Task { if await chat.send(sending, images: outgoing, files: outgoingFiles) { if draft == sending { draft = "" }; images = []; files = []; selectedPhotos = [] } }
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
    static func displayRows(_ messages: [JSONValue]) -> [Row] {
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { expanded.toggle() } label: { Label(title, systemImage: "terminal").lineLimit(1) }
                Spacer()
                Text(execution["status"].string).font(.caption2)
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
            .background(Color(red: 0.12, green: 0.14, blue: 0.18)).presentationDetents([.large])
        }
    }
    private var output: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 8) {
                Text(execution["status"].string)
                if !execution["cwd"].string.isEmpty { Text(execution["cwd"].string) }
                if execution["exitCode"] != .null { Text("Exit \(Int(execution["exitCode"].number))") }
                if !execution["command"].string.isEmpty { Text("$ " + execution["command"].string) }
                ForEach(Array(execution["files"].array.enumerated()), id: \.offset) { _, file in
                    Text(file["path"].string).foregroundStyle(.cyan)
                    code(file["diff"].string.isEmpty ? "No diff returned by the server." : file["diff"].string)
                    if file["truncated"].bool { Text("Saved diff is partial.").foregroundStyle(.yellow) }
                }
                if !execution["output"].string.isEmpty { code(execution["output"].string) }
                if execution["output"].string.isEmpty && execution["files"].array.isEmpty { Text("No output received yet.") }
                if execution["truncated"].bool || execution["filesTruncated"].bool { Text("The saved output is partial.").foregroundStyle(.yellow) }
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func code(_ value: String) -> some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(value.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : line.hasPrefix("@@") ? Color.cyan : Color.white.opacity(0.9))
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thinking").font(.caption).italic()
                    if !message["metadata"]["thoughtSummary"].string.isEmpty {
                        Text(message["metadata"]["thoughtSummary"].string).font(.system(size: 13)).textSelection(.enabled)
                    }
                    ForEach(activities) { item in
                        if item["metadata"]["execution"] != .null { MiniTerminal(execution: item["metadata"]["execution"]) }
                        else {
                            Text(item["metadata"]["thoughtSummary"].string.isEmpty ? item["content"].string : item["metadata"]["thoughtSummary"].string).font(.system(size: 13)).textSelection(.enabled)
                        }
                    }
                    ForEach(Array(liveEvents.enumerated()), id: \.offset) { _, event in Text(event).font(.system(size: 12, design: .monospaced)) }
                    if activities.isEmpty && liveEvents.isEmpty && message["metadata"]["thoughtSummary"].string.isEmpty {
                        Text("No saved details for this message.").font(.caption)
                    }
                }.foregroundStyle(VesperTheme.muted).padding(.vertical, 4)
            }
        }
    }
}
