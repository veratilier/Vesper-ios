import SwiftUI

struct ChatDraftField: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @ObservedObject var text: ChatDraftText
    let listening: Bool
    let focused: FocusState<Bool>.Binding
    var body: some View {
        TextField(listening ? "Listening…" : "Write to \(chat.contactName)…", text: $text.value, axis: .vertical)
            .lineLimit(1...5)
            .focused(focused)
            .font(.system(size: 16))
    }
}

struct ChatSendButton: View {
    @ObservedObject var text: ChatDraftText
    let hasNonTextPayload: Bool
    let blocked: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 27)).frame(width: 40, height: 40)
        }
        .disabled((text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasNonTextPayload) || blocked)
        .accessibilityLabel("Send")
    }
}

/// Anchored to the composer so the three choices open above the input field.
struct ChatModelPopover: View {
    enum Page { case overview, model, strength }
    let initialPage: Page
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 36
    @State private var page: Page
    init(initialPage: Page = .overview) {
        self.initialPage = initialPage
        _page = State(initialValue: initialPage)
    }
    private var locked: Bool { store.loading || !chat.canSwitchBackend }
    private var modelName: String {
        guard !chat.model.isEmpty else { return "Default" }
        let name = chat.models.first { $0["model"].string == chat.model }?["displayName"].string ?? ""
        return name.isEmpty ? chat.model : name
    }
    private func effortName(_ value: String) -> String {
        value.isEmpty ? "Default" : value == "xhigh" ? "Extra high" : value.capitalized
    }
    var body: some View {
        VStack(spacing: 4) {
            if page != .overview {
                HStack(spacing: 8) {
                    Text(page == .model ? "Model" : "Strength").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                        .accessibilityLabel("Close model picker")
                }
            }
            Group {
                switch page {
                case .overview: overview
                case .model: modelChoices
                case .strength: strengthChoices
                }
            }
        }
        .padding(10)
        .frame(idealWidth: 220, maxWidth: 220)
        .foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink).buttonStyle(.plain)
        .preferredColorScheme(VesperTheme.palette == .black ? .dark : .light)
        .accessibilityIdentifier("chat-model-popover")
        .onAppear { page = initialPage }
    }
    private var overview: some View {
        VStack(spacing: 8) {
            selectionRow("Model", value: modelName, symbol: "cpu") { page = .model }
                .disabled(locked)
            selectionRow("Strength", value: effortName(chat.effort), symbol: "sparkles") { page = .strength }
                .disabled(locked)
            modelStatus
        }
    }
    private func selectionRow(_ title: String, value: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).font(.subheadline)
                Spacer(minLength: 4)
                Text(value).font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption)
            }.font(.subheadline).frame(minHeight: rowHeight)
        }.accessibilityIdentifier("chat-choose-" + title.lowercased())
    }
    private var modelChoices: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    choice("Default model", selected: chat.model.isEmpty) { chat.selectModel(""); finishSelection() }
                    ForEach(chat.models) { model in
                        choice(model["displayName"].string.isEmpty ? model["model"].string : model["displayName"].string,
                               selected: chat.model == model["model"].string) {
                            chat.selectModel(model["model"].string); finishSelection()
                        }
                    }
                }
            }.frame(height: min(CGFloat(chat.models.count + 1) * rowHeight, 160)).scrollBounceBehavior(.basedOnSize)
            modelStatus
            Button("Refresh models") { Task { await chat.loadModels() } }.font(.caption).frame(minHeight: 36).disabled(chat.loadingModels)
        }
    }
    private var strengthChoices: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach([""] + chat.supportedEfforts, id: \.self) { value in
                        choice(effortName(value), selected: chat.effort == value) { chat.effort = value; finishSelection() }
                    }
                }
            }.frame(height: min(CGFloat(chat.supportedEfforts.count + 1) * rowHeight, 160)).scrollBounceBehavior(.basedOnSize)
            if chat.supportedEfforts.isEmpty {
                Text(chat.model.isEmpty ? "Choose a model to see its supported strength levels." : "This model does not offer adjustable reasoning strength.")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
            }
            modelStatus
        }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                if selected { Image(systemName: "checkmark").font(.subheadline.weight(.semibold)) }
            }.padding(.horizontal, 8).frame(minHeight: rowHeight)
                .background(selected ? VesperTheme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.disabled(locked).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func finishSelection() {
        if initialPage == .overview { page = .overview } else { dismiss() }
    }
    @ViewBuilder private var modelStatus: some View {
        if chat.loadingModels { ProgressView(chat.models.isEmpty ? "Loading models…" : "Updating models…").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
        if chat.modelCatalogCached { Text("Saved model list").font(.caption).foregroundStyle(VesperTheme.muted) }
        if let error = chat.modelError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry models") { Task { await chat.loadModels() } }.font(.caption).frame(minHeight: 36).disabled(chat.loadingModels)
        }
    }
}


struct ChatQueuedBubble: View {
    let message: ChatQueuedMessage
    let canRemove: Bool
    let onRemove: () -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 42)
            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    if let quote = message.replyTo { ChatQuotePreview(quote: quote) }
                    if !message.images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                                    ChatDraftPhoto(data: data, size: 72)
                                }
                            }
                        }.frame(maxWidth: 250)
                    }
                    ForEach(message.files) { file in
                        Label(file.name, systemImage: file.mime.hasPrefix("video/") ? "video" : (file.mime.hasPrefix("audio/") ? "waveform" : "doc")).font(.system(size: 13)).lineLimit(2)
                    }
                    if let music = message.music { ChatMusicCard(track: music) }
                    if let sticker = message.sticker { StickerArtwork(sticker: sticker).frame(width: 100, height: 100) }
                    if let location = message.location { ChatLocationCard(location: location) }
                    if !message.text.isEmpty { Text(message.text).font(.system(size: 15)).lineSpacing(2) }
                }.modifier(ChatBubbleSurface(user: true))
            }.contextMenu {
                Button("撤回这条", systemImage: "arrow.uturn.backward", action: onRemove).disabled(!canRemove)
            }
        }.accessibilityElement(children: .contain)
    }
}
