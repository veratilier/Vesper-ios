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
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.65)))
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
            .vesperMaterial(.thinMaterial, in: shape)
            .overlay(shape.stroke(.white.opacity(0.45), lineWidth: 0.7))
    }
}
