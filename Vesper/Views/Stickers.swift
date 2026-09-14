import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit

struct StickerLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    var onSelect: ((JSONValue) -> Void)? = nil
    @State private var stickers: [JSONValue] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var busy = false
    @State private var query = ""
    @State private var status = ""
    @State private var importDescription = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shared with your web sticker library. Rowan can find these with sticker search.").font(.caption).foregroundStyle(.secondary)
                TextField("Description (optional), e.g. happy, hug", text: $importDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder).disabled(busy)
                Text("Applies to every image in your next import. Leave blank if you prefer.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) { Label("Import photos", systemImage: "photo.badge.plus") }
                    Button { importing = true } label: { Label("Import files", systemImage: "folder.badge.plus") }
                }.buttonStyle(.bordered).disabled(busy)
                if busy { ProgressView("Importing…") }
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                if stickers.isEmpty && !busy { Text("No stickers yet. Import an image above.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 14) {
                    ForEach(stickers, id: \.selfID) { sticker in
                        Button { onSelect?(sticker) } label: {
                            VStack {
                                StickerArtwork(sticker: sticker).frame(height: 90)
                                Text(sticker["name"].string).font(.caption).lineLimit(2)
                            }
                        }.buttonStyle(.plain).disabled(onSelect == nil || chat.busy || busy)
                    }
                }
            }.padding()
        }
        .navigationTitle("Stickers").navigationBarTitleDisplayMode(.inline)
        .toolbar { if onSelect != nil { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
        .searchable(text: $query, prompt: "Search stickers").onSubmit(of: .search) { Task { await load() } }
        .task { await load() }.refreshable { await load() }
        .onChange(of: photos) { _, picks in
            guard !picks.isEmpty else { return }
            busy = true
            Task {
                var count = 0
                do {
                    for pick in picks {
                        guard let data = try await pick.loadTransferable(type: Data.self) else { throw ServiceError(message: "Could not read this photo.") }
                        let type = pick.supportedContentTypes.first ?? .png
                        try await upload(data, name: "Sticker-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "png")", type: type)
                        count += 1
                    }
                    status = "Imported \(count) stickers."
                    importDescription = ""
                } catch { status = "Imported \(count). " + error.localizedDescription }
                photos = []; busy = false; await load()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            busy = true
            Task {
                var count = 0
                do {
                    for url in try result.get() {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 16 * 1024 * 1024 else { throw ServiceError(message: "Choose stickers under 16 MB.") }
                        try await upload(Data(contentsOf: url), name: url.lastPathComponent, type: UTType(filenameExtension: url.pathExtension) ?? .image)
                        count += 1
                    }
                    status = "Imported \(count) stickers."
                    importDescription = ""
                } catch { status = "Imported \(count). " + error.localizedDescription }
                busy = false; await load()
            }
        }
    }
    private func load() async {
        do {
            var components = URLComponents(); components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "200")]
            let result = try await store.api.request("/api/stickers?" + (components.percentEncodedQuery ?? ""))
            stickers = result["stickers"].array
        } catch { status = error.localizedDescription }
    }
    private func upload(_ data: Data, name: String, type: UTType) async throws {
        guard data.count <= 16 * 1024 * 1024 else { throw ServiceError(message: "Choose stickers under 16 MB.") }
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            guard let image = UIImage(data: data), let png = image.pngData() else { throw ServiceError(message: "Could not prepare this image.") }
            _ = try await store.api.uploadFile(png, name: (name as NSString).deletingPathExtension + ".png", mime: "image/png", sticker: true, description: importDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            _ = try await store.api.uploadFile(data, name: name, mime: type.preferredMIMEType ?? "application/octet-stream", sticker: true, description: importDescription.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private extension JSONValue {
    var selfID: String { self["assetId"].string }
}

/// WebKit preserves animated GIF/WebP and transparent pixels without a photo crop.
struct StickerArtwork: UIViewRepresentable {
    let sticker: JSONValue
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let source = sticker["url"].string
        guard view.accessibilityIdentifier != source else { return }
        view.accessibilityIdentifier = source
        view.accessibilityLabel = sticker["description"].string.isEmpty ? "Sticker" : sticker["description"].string
        guard let url = URL(string: source), url.scheme == "https", url.host != nil else { view.loadHTMLString("Sticker unavailable", baseURL: nil); return }
        let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        view.loadHTMLString("<meta name='viewport' content='width=device-width, initial-scale=1'><style>html,body{margin:0;width:100%;height:100%;background:transparent}img{width:100%;height:100%;object-fit:contain}</style><img alt='Sticker unavailable' src=\"\(escaped)\">", baseURL: nil)
    }
}
