import SwiftUI

struct ChatDraftField: View {
    @ObservedObject var text: ChatDraftText
    let listening: Bool
    let focused: FocusState<Bool>.Binding
    var body: some View {
        TextField(listening ? "Listening…" : "Write to Rowan…", text: $text.value, axis: .vertical)
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
    private enum Page { case overview, model, strength }
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.chatWorkspace) private var workspace
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @State private var page = Page.overview
    @State private var switchError: String?
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
                    Button { page = .overview } label: { Image(systemName: "chevron.left").frame(width: 36, height: 44) }
                        .accessibilityLabel("Back to chat settings")
                    Text(page == .model ? "Model" : "Strength").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 36) }
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
            if let switchError { Text(switchError).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(12)
        .frame(width: min(252, UIScreen.main.bounds.width - 32))
        .foregroundStyle(VesperTheme.ink).tint(VesperTheme.ink).buttonStyle(.plain)
        .preferredColorScheme(VesperTheme.palette == .black ? .dark : .light)
        .accessibilityIdentifier("chat-model-popover")
    }
    private var overview: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(VesperBackend.allCases) { backend in
                    Button { openBackendWindow(backend) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: backend == .vps ? "server.rack" : "laptopcomputer")
                            Text(backend == .vps ? "VPS" : "MAC").fontWeight(.semibold)
                            if store.activeBackend == backend { Image(systemName: "checkmark").font(.caption.bold()) }
                        }.font(.subheadline).frame(maxWidth: .infinity, minHeight: rowHeight)
                            .background(store.activeBackend == backend ? VesperTheme.accent.opacity(0.22) : VesperTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.activeBackend == backend ? VesperTheme.accent : .clear, lineWidth: 1))
                    }
                    .accessibilityIdentifier("chat-backend-" + backend.rawValue)
                    .accessibilityAddTraits(store.activeBackend == backend ? .isSelected : [])
                }
            }
            Divider().padding(.vertical, 2)
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
                    choice("Default model", selected: chat.model.isEmpty) { chat.selectModel(""); page = .overview }
                    ForEach(chat.models) { model in
                        choice(model["displayName"].string.isEmpty ? model["model"].string : model["displayName"].string,
                               selected: chat.model == model["model"].string) {
                            chat.selectModel(model["model"].string); page = .overview
                        }
                    }
                }
            }.frame(height: min(CGFloat(chat.models.count + 1) * rowHeight, 260)).scrollBounceBehavior(.basedOnSize)
            modelStatus
            Button("Refresh models") { Task { await chat.loadModels() } }.font(.caption).frame(minHeight: 36).disabled(chat.loadingModels)
        }
    }
    private var strengthChoices: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach([""] + chat.supportedEfforts, id: \.self) { value in
                        choice(effortName(value), selected: chat.effort == value) { chat.effort = value; page = .overview }
                    }
                }
            }.frame(height: min(CGFloat(chat.supportedEfforts.count + 1) * rowHeight, 260)).scrollBounceBehavior(.basedOnSize)
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
    @ViewBuilder private var modelStatus: some View {
        if chat.loadingModels { ProgressView("Loading models…").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
        if let error = chat.modelError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry models") { Task { await chat.loadModels() } }.font(.caption).frame(minHeight: 36).disabled(chat.loadingModels)
        }
    }
    @MainActor private func openBackendWindow(_ backend: VesperBackend) {
        guard backend != store.activeBackend else { return }
        switchError = nil
        do {
            guard let workspace else { throw ServiceError(message: "The other chat window is unavailable.") }
            try workspace.select(backend, openChat: true)
            dismiss()
        } catch { switchError = error.localizedDescription }
    }
}
