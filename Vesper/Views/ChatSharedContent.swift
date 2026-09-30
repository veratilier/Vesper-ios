import SwiftUI
import SafariServices
import LinkPresentation
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

// Deduplicate visible cards and cache failures briefly. No chat credentials are
// included in metadata requests, and scrolling back does not refetch each link.
@MainActor private final class ChatLinkMetadataCache {
    static let shared = ChatLinkMetadataCache()
    private final class Entry: NSObject {
        let metadata: LPLinkMetadata?
        let expires: Date
        init(_ metadata: LPLinkMetadata?) {
            self.metadata = metadata
            expires = Date().addingTimeInterval(metadata == nil ? 30 : 3600)
        }
    }
    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>(); cache.countLimit = 80; return cache
    }()
    private var loading: [URL: Task<LPLinkMetadata?, Never>] = [:]
    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let entry = cache.object(forKey: url as NSURL), entry.expires > Date() { return entry.metadata }
        if let task = loading[url] { return await task.value }
        // Fast scrolling must not start a WebKit metadata load for every old row.
        while loading.count >= 3, let next = loading.values.first {
            _ = await next.value
            guard !Task.isCancelled else { return nil }
            if let entry = cache.object(forKey: url as NSURL), entry.expires > Date() { return entry.metadata }
            if let task = loading[url] { return await task.value }
        }
        let task = Task { @MainActor () -> LPLinkMetadata? in
            let provider = LPMetadataProvider()
            provider.timeout = 8
            let value = try? await provider.startFetchingMetadata(for: url)
            cache.setObject(Entry(value), forKey: url as NSURL)
            loading[url] = nil
            return value
        }
        loading[url] = task
        return await task.value
    }
}

struct ChatLinkCard: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?
    init(url: URL, metadata: LPLinkMetadata? = nil) {
        self.url = url
        _metadata = State(initialValue: metadata)
    }
    var body: some View {
        Link(destination: url) {
            Group {
                if let metadata { ChatLinkArtwork(metadata: metadata).allowsHitTesting(false) }
                else {
                    HStack(spacing: 12) {
                        Image(systemName: "link").font(.title2).foregroundStyle(VesperTheme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(url.host ?? "Link").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(url.path.isEmpty || url.path == "/" ? url.absoluteString : url.path)
                                .font(.caption).foregroundStyle(VesperTheme.muted).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }.padding(14).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                        .background(.regularMaterial)
                }
            }.frame(maxWidth: 280).clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open link: \(metadata?.title ?? url.host ?? url.absoluteString)")
        .modifier(ChatInAppLinks())
        .task(id: url) {
            guard metadata == nil else { return }
            let value = await ChatLinkMetadataCache.shared.metadata(for: url)
            guard !Task.isCancelled else { return }
            metadata = value
        }
    }
}

private struct ChatLinkArtwork: UIViewRepresentable {
    let metadata: LPLinkMetadata
    func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }
    func updateUIView(_ view: LPLinkView, context: Context) {
        if view.metadata !== metadata { view.metadata = metadata }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        return CGSize(width: width, height: uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
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
