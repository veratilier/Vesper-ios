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
            Image(systemName: "arrow.up").font(.system(size: 21, weight: .semibold)).frame(width: 40, height: 40).vesperGlass(in: Circle(), interactive: true)
        }
        .disabled((text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasNonTextPayload) || blocked)
        .accessibilityLabel("Send")
    }
}
