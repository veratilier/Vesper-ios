import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit

struct StickerLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    var onSelect: ((JSONValue) -> Void)? = nil
    @State private var editing = false
    @State private var loading = false
    @State private var selected: JSONValue?
    @State private var editName = ""
    @State private var editDescription = ""
    @State private var confirmDelete = false
    @State private var editError = ""
    @State private var saving = false
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
                if editing {
                    Text("Add stickers or tap one to edit its name, description or delete it.").font(.caption).foregroundStyle(VesperTheme.muted)
                    TextField("Description for new stickers (optional)", text: $importDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder).disabled(busy)
                    HStack {
                        PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) { Label("Add photos", systemImage: "photo.badge.plus") }
                        Button { importing = true } label: { Label("Add files", systemImage: "folder.badge.plus") }
                    }.buttonStyle(.bordered).disabled(busy)
                }
                if busy || loading { ProgressView(busy ? "Importing…" : "Loading…") }
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 20) {
                    if !editing {
                        Button { editing = true } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 27, weight: .light))
                                .frame(maxWidth: .infinity).frame(height: 76)
                                .background(VesperTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VesperTheme.muted.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5])))
                        }.buttonStyle(.plain).accessibilityLabel("Edit stickers").disabled(busy)
                    }
                    ForEach(stickers, id: \.selfID) { sticker in
                        Button {
                            if editing { selected = sticker; editName = sticker["name"].string; editDescription = sticker["description"].string; editError = "" }
                            else { onSelect?(sticker) }
                        } label: {
                            StickerArtwork(sticker: sticker).frame(height: 76)
                        }.buttonStyle(.plain).accessibilityLabel(sticker["description"].string.isEmpty ? sticker["name"].string : sticker["description"].string)
                            .disabled((!editing && (onSelect == nil || chat.busy)) || busy)
                    }
                }
                if stickers.isEmpty && !loading && !busy {
                    Text("No stickers yet. Tap Edit to add your favorites.").font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
            }.padding(18)
        }.background { Background() }.foregroundStyle(VesperTheme.ink)
        .navigationTitle(editing ? "Edit stickers" : "Stickers").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { if editing { editing = false } else { dismiss() } }.disabled(busy)
            }
        }
        .task { await load() }.refreshable { await load() }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) { editor }
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
    private var editor: some View {
        NavigationStack {
            Form {
                if let selected { StickerArtwork(sticker: selected).frame(height: 150).frame(maxWidth: .infinity) }
                TextField("Name", text: $editName)
                TextField("Description", text: $editDescription, axis: .vertical)
                if !editError.isEmpty { Text(editError).font(.caption).foregroundStyle(.red) }
                Button("Delete sticker", role: .destructive) { confirmDelete = true }
            }.disabled(saving).navigationTitle("Edit sticker").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selected = nil }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await saveSticker(delete: false) } }.disabled(saving || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .confirmationDialog("Delete this sticker? Existing messages will show an unavailable image.", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await saveSticker(delete: true) } }
                }
        }.presentationDetents([.medium, .large])
    }
    private func saveSticker(delete: Bool) async {
        guard let selected, !saving else { return }
        let assetID = selected["assetId"].string
        guard !assetID.isEmpty, let encoded = assetID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        saving = true; editError = ""; defer { saving = false }
        do {
            let result = try await store.api.request("/api/stickers/" + encoded, method: delete ? "DELETE" : "PATCH", body: delete ? nil : .object(["name": .string(editName.trimmingCharacters(in: .whitespacesAndNewlines)), "description": .string(editDescription)]))
            if !delete { guard result["sticker"]["assetId"].string == assetID else { throw ServiceError(message: "The sticker update was not confirmed.") } }
            self.selected = nil; status = delete ? "Sticker deleted." : "Sticker saved."
            await load()
        } catch { editError = error.localizedDescription }
    }
    private func load() async {
        loading = true; defer { loading = false }
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
