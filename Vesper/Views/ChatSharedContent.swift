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
        }.padding(14).frame(width: 280, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine).accessibilityHint("Preview file")
    }
}
