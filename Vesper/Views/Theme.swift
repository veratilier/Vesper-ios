import SwiftUI

enum VesperTheme {
    static let ink = Color(red: 0.17, green: 0.23, blue: 0.27)
    static let muted = Color(red: 0.43, green: 0.51, blue: 0.55)
    static let accent = Color(red: 0.48, green: 0.65, blue: 0.74)
    static func title(_ size: CGFloat = 32) -> Font { .custom("Ballet-Regular", size: size, relativeTo: .title) }
}
struct Background: View {
    var body: some View {
        GeometryReader { g in
            Image("Marble").resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                .overlay(Color.white.opacity(0.16))
        }.ignoresSafeArea()
    }
}
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(.white.opacity(0.8), lineWidth: 1.5))
    }
}
struct Page<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(VesperTheme.title(38))
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(VesperTheme.muted) }
                }.padding(.vertical, 8)
                content
            }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively)
    }
}
struct EmptyCard: View {
    let title: String
    let message: String
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(VesperTheme.muted).font(.subheadline)
            }.padding(.vertical, 12)
        }
    }
}
struct FormField: View {
    let label: String
    @Binding var text: String
    var multiline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(VesperTheme.muted)
            if multiline {
                TextEditor(text: $text).frame(minHeight: 160).scrollContentBackground(.hidden)
            } else { TextField(label, text: $text) }
        }.padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct EditorSheet<Content: View>: View {
    let title: String
    var busy = false
    let save: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack { Background(); ScrollView { VStack(spacing: 16) { content }.padding(20) } }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(busy) }
                }
        }.presentationDragIndicator(.visible)
    }
}
