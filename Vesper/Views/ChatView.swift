import SwiftUI
import UIKit
import PhotosUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @State private var draft = ""
    @State private var history = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var images: [Data] = []
    @State private var loadingPhotos = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { Task { await chat.loadConversations(); history = true } } label: { Label("Conversations", systemImage: "tray") }
                Spacer()
                Button { chat.newConversation() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New conversation").disabled(chat.busy)
            }.font(.caption).padding(.horizontal, 20).padding(.vertical, 12)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.messages.isEmpty { Text("A little space for us.").font(VesperTheme.title(30)).foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity).padding(.top, 70) }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message["role"].string == "user" ? "Vera" : "Rowan").font(.caption.weight(.medium)).foregroundStyle(VesperTheme.muted)
                                if !message["metadata"]["attachments"].array.isEmpty {
                                    ScrollView(.horizontal) { HStack { ForEach(Array(message["metadata"]["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                                        if attachment["type"].string.hasPrefix("image/") { Artwork(url: attachment["url"].string).frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 15)) }
                                        else if let url = URL(string: attachment["url"].string) { Link(attachment["name"].string, destination: url) }
                                    } } }
                                }
                                Text(message["content"].string).font(.system(size: 15)).lineSpacing(5).textSelection(.enabled)
                                if message["status"].string == "error" { Text("Send not confirmed").font(.caption).foregroundStyle(.red) }
                                if message["status"].string != "streaming" {
                                    HStack { Text(message["createdAt"].string).font(.caption2); Spacer(); Button { UIPasteboard.general.string = message["content"].string } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("Copy message") }.foregroundStyle(VesperTheme.muted)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).id(message.id)
                        }
                        if !chat.events.isEmpty {
                            DisclosureGroup("Activity · \(chat.events.count)") { ForEach(Array(chat.events.enumerated()), id: \.offset) { _, event in Text(event).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3) } }.font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        if !chat.status.isEmpty { HStack { if chat.busy { ProgressView().controlSize(.small) }; Text(chat.status).font(.caption) }.foregroundStyle(VesperTheme.muted) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(20)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
        }
        // Native keyboard avoidance: no WebView, keyboard toolbar, artificial keyboard height or bottom spacer.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if !images.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topTrailing) { Button { images.remove(at: index) } label: { Image(systemName: "xmark.circle.fill").background(.white, in: Circle()) }.accessibilityLabel("Remove photo").disabled(chat.busy) } }
                    } } }
                }
                TextField("Write to Rowan…", text: $draft, axis: .vertical).lineLimit(1...6).focused($focused).font(.system(size: 16))
                HStack {
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 5, matching: .images) { Image(systemName: "plus").font(.title3) }.disabled(chat.busy || loadingPhotos).accessibilityLabel("Attach photos")
                    Picker("Model", selection: $chat.model) { Text("Default model").tag(""); ForEach(chat.models) { model in Text(model["displayName"].string.isEmpty ? model["model"].string : model["displayName"].string).tag(model["model"].string) } }.font(.caption).disabled(chat.busy)
                    Spacer()
                    if chat.busy { Button { Task { await chat.interrupt() } } label: { Image(systemName: "stop.circle.fill").font(.title) }.accessibilityLabel("Stop reply") }
                    else { Button { let sending = draft; let outgoing = images; Task { if await chat.send(sending, images: outgoing) { if draft == sending { draft = "" }; images = []; selectedPhotos = [] } } } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }.disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) || loadingPhotos).accessibilityLabel("Send message") }
                }
            }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.8), lineWidth: 1.5)).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .task { chat.configure(store) }
        .onChange(of: selectedPhotos) { _, picks in
            guard !picks.isEmpty else { return }
            loadingPhotos = true
            Task {
                var loaded: [Data] = []
                for pick in picks {
                    do {
                        guard let bytes = try await pick.loadTransferable(type: Data.self), let image = UIImage(data: bytes), let jpeg = image.jpegData(compressionQuality: 0.8) else { throw ServiceError(message: "Could not read this photo.") }
                        guard jpeg.count <= 16 * 1024 * 1024 else { throw ServiceError(message: "Choose a smaller photo (under 16 MB).") }
                        loaded.append(jpeg)
                    } catch { chat.error = error.localizedDescription }
                }
                images = loaded; loadingPhotos = false
            }
        }
        .onDisappear { if !chat.busy { chat.disconnect() } }
        .sheet(isPresented: $history) {
            NavigationStack { List(chat.conversations) { item in Button { Task { await chat.open(item); history = false } } label: { VStack(alignment: .leading) { Text(item["title"].string); Text(item["updatedAt"].string).font(.caption).foregroundStyle(.secondary) } }.disabled(chat.busy) }.navigationTitle("Conversations") }
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
        .alert("Chat", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) { Button("OK") { chat.error = nil } } message: { Text(chat.error ?? "") }
    }
}
