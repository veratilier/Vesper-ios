import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit
import Vision
import CoreImage
import ImageIO

struct StickerLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    var compact = false
    var onBack: (() -> Void)? = nil
    var editingInitially = false
    var onSelect: ((JSONValue) -> Void)? = nil
    @State private var managing = false
    @State private var editing = false
    @State private var loading = false
    @State private var selected: StickerSelection?
    @State private var editName = ""
    @State private var editDescription = ""
    @State private var editCategory = ""
    @State private var editFavorite = false
    @State private var confirmDelete = false
    @State private var editError = ""
    @State private var saving = false
    @State private var removingBackground = false
    @State private var transparentPreview: Data?
    @State private var stickers: [JSONValue] = []
    @State private var categories: [JSONValue] = []
    @State private var filter = "all"
    @State private var submittedQuery = ""
    @State private var loadID = UUID()
    @State private var selecting = false
    @State private var selection: [JSONValue] = []
    @State private var batchEditor = false
    @State private var batchEdit = StickerBatchEdit()
    @State private var confirmBatchDelete = false
    @State private var categoryDialog = false
    @State private var categoryName = ""
    @State private var renamingCategory: String?
    @State private var deletingCategoryID: String?
    @State private var deletingCategoryName = ""
    @State private var confirmCategoryDelete = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingPhotos = false
    @State private var adding = false
    @State private var importing = false
    @State private var busy = false
    @State private var query = ""
    @State private var status = ""
    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { onBack?() } label: { Image(systemName: "chevron.left").frame(width: 36, height: 32) }
                            .accessibilityLabel("Back to attachments")
                        Text("Stickers").font(.system(size: 13, weight: .medium))
                        Spacer()
                    }.buttonStyle(.plain).padding(.horizontal, 14)
                    libraryContents
                }
            } else {
                libraryContents
                    .navigationTitle(editing ? "Edit stickers" : "Stickers").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                if selecting { selecting = false; selection = [] }
                                else if editing && !editingInitially { editing = false }
                                else { dismiss() }
                            }.disabled(busy)
                        }
                    }
            }
        }.foregroundStyle(VesperTheme.ink)
        .background { if !compact { Background() } }
        .onAppear { if editingInitially { editing = true } }
        .task(id: filter + "|" + submittedQuery) { await load() }
        .sheet(isPresented: $managing, onDismiss: { Task { await load() } }) {
            NavigationStack { StickerLibraryView(editingInitially: true) }
        }
        .sheet(item: $selected) { selection in editor(selection.sticker) }
        .sheet(isPresented: $batchEditor) { batchEditorContents }
        .confirmationDialog("Add stickers", isPresented: $adding, titleVisibility: .visible) {
            Button("Photo library") { pickingPhotos = true }
            Button("Choose files") { importing = true }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photos, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current)
        .alert(renamingCategory == nil ? "New category" : "Rename category", isPresented: $categoryDialog) {
            TextField("Category name", text: $categoryName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { Task { await saveCategory() } }
                .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete \(selection.count) stickers?", isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("Delete selected stickers", role: .destructive) { Task { await applyBatch(delete: true) } }
        } message: { Text("This also makes these stickers unavailable in existing messages.") }
        .confirmationDialog("Delete “\(deletingCategoryName)” category?", isPresented: $confirmCategoryDelete, titleVisibility: .visible) {
            Button("Delete category", role: .destructive) { Task { await deleteCategory() } }
        } message: { Text("Its stickers will move to Uncategorized. No stickers will be deleted.") }
        .interactiveDismissDisabled(busy)
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
                } catch { status = "Imported \(count). " + error.localizedDescription }
                busy = false; await load()
            }
        }
    }
    private var libraryContents: some View {
        VStack(spacing: 0) {
        categoryStrip
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if editing {
                    HStack {
                        if selecting {
                            Text("\(selection.count) selected").font(.subheadline.weight(.semibold))
                            Button(allVisibleSelected ? "Deselect visible" : "Select visible") { toggleVisibleSelection() }
                                .font(.subheadline).disabled(busy || loading || stickers.isEmpty)
                        } else {
                            Button { adding = true } label: { Label("Add", systemImage: "plus") }
                                .disabled(busy)
                        }
                        Spacer()
                        Button(selecting ? "Cancel" : "Select") { selecting.toggle(); selection = [] }.disabled(busy)
                    }
                }
                if !compact {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                        TextField("Search stickers", text: $query).submitLabel(.search)
                            .onSubmit { submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines) }
                        if !query.isEmpty {
                            Button { query = ""; submittedQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Clear search")
                        }
                    }.padding(12).vesperGlass(in: RoundedRectangle(cornerRadius: 16)).disabled(busy)
                }
                if busy || loading { ProgressView(busy ? "Saving…" : "Loading…") }
                if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: compact ? 12 : 20) {
                    if !editing {
                        Button { if compact { managing = true } else { editing = true } } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 27, weight: .light))
                                .frame(maxWidth: .infinity).frame(height: 76)
                                .vesperGlass(in: RoundedRectangle(cornerRadius: 12), interactive: true)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(VesperTheme.muted.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5])))
                        }.buttonStyle(.plain).accessibilityLabel("Edit stickers").disabled(busy)
                    }
                    ForEach(stickers, id: \.selfID) { sticker in
                        StickerTile(sticker: sticker) {
                            if selecting { toggleSelection(sticker) }
                            else if editing { openEditor(sticker) }
                            else { onSelect?(sticker) }
                        }.overlay(alignment: .topTrailing) {
                            if selecting {
                                Image(systemName: selection.contains(where: { $0["assetId"] == sticker["assetId"] }) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(VesperTheme.ink)
                                    .background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                            }
                        }
                        .accessibilityValue(selecting ? (selection.contains(where: { $0["assetId"] == sticker["assetId"] }) ? "Selected" : "Not selected") : "")
                        .disabled((!editing && (onSelect == nil || chat.busy)) || busy || loading)
                    }
                }
                if stickers.isEmpty && !loading && !busy {
                    Text("No stickers here yet. Add some or move stickers into this category.").font(.subheadline).foregroundStyle(VesperTheme.muted)
                }
                if stickers.count >= 48 {
                    Text("Showing the latest results. Choose a category or search to find older stickers.")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                }
            }.padding(.horizontal, compact ? 20 : 18).padding(.vertical, compact ? 10 : 18)
        }.refreshable { await load() }
        if selecting { batchActions }
        }
    }
    private var activeCategoryID: String { filter == "all" || filter == "favorites" ? "" : filter }
    private var allVisibleSelected: Bool {
        !stickers.isEmpty && stickers.allSatisfy { item in selection.contains { $0["assetId"] == item["assetId"] } }
    }
    private var categoryStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryButton("All", id: "all", icon: "square.grid.2x2")
                    categoryButton("Favorites", id: "favorites", icon: "heart")
                    ForEach(categories) { category in
                        categoryButton(category["name"].string, id: category.id, icon: "face.smiling")
                    }
                }.padding(.vertical, 8)
            }
            if editing {
                Menu {
                    Button("New category", systemImage: "folder.badge.plus") {
                        renamingCategory = nil; categoryName = ""; categoryDialog = true
                    }
                    if let category = categories.first(where: { $0.id == filter }) {
                        Button("Rename category", systemImage: "pencil") {
                            renamingCategory = category.id; categoryName = category["name"].string; categoryDialog = true
                        }
                        Button(role: .destructive) {
                            deletingCategoryID = category.id
                            deletingCategoryName = category["name"].string
                            confirmCategoryDelete = true
                        } label: { Label("Delete category", systemImage: "trash") }
                    }
                } label: { Image(systemName: "folder.badge.gearshape").frame(width: 36, height: 40) }
                    .accessibilityLabel("Manage categories")
            }
        }.padding(.horizontal, compact ? 14 : 18).disabled(busy)
    }
    private func categoryButton(_ title: String, id: String, icon: String) -> some View {
        Button {
            guard filter != id else { return }
            stickers = []; status = ""; filter = id
        } label: {
            Label(title, systemImage: icon).font(.system(size: compact ? 12 : 14, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(filter == id ? VesperTheme.ink.opacity(0.16) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(filter == id ? VesperTheme.ink.opacity(0.3) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(filter == id ? .isSelected : [])
    }
    private func categoryPicker(selection: Binding<String>) -> some View {
        Picker("Category", selection: selection) {
            Text("Uncategorized").tag("")
            ForEach(categories) { Text($0["name"].string).tag($0.id) }
        }
    }
    private func openEditor(_ sticker: JSONValue) {
        transparentPreview = nil; editName = sticker["name"].string; editDescription = sticker["description"].string
        editCategory = sticker["categoryId"].string; editFavorite = sticker["favorite"].bool; editError = ""
        selected = StickerSelection(sticker: sticker)
    }
    private func toggleSelection(_ sticker: JSONValue) {
        if let index = selection.firstIndex(where: { $0["assetId"] == sticker["assetId"] }) { selection.remove(at: index) }
        else { selection.append(sticker) }
    }
    private func toggleVisibleSelection() {
        if allVisibleSelected {
            let ids = Set(stickers.map { $0["assetId"].string })
            selection.removeAll { ids.contains($0["assetId"].string) }
        } else {
            for sticker in stickers where !selection.contains(where: { $0["assetId"] == sticker["assetId"] }) { selection.append(sticker) }
        }
    }
    private var batchActions: some View {
        HStack(spacing: 22) {
            Menu {
                Button("Uncategorized") { moveSelection(to: "") }
                ForEach(categories) { category in
                    Button(category["name"].string) { moveSelection(to: category.id) }
                }
            } label: { Label("Move", systemImage: "folder") }
            Button { batchEdit = StickerBatchEdit(); batchEditor = true } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { confirmBatchDelete = true } label: { Label("Delete", systemImage: "trash") }
        }.font(.subheadline).buttonStyle(.plain).padding(16).frame(maxWidth: .infinity)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 16).padding(.bottom, 10).disabled(busy || selection.isEmpty)
    }
    private func moveSelection(to category: String) {
        batchEdit = StickerBatchEdit(); batchEdit.changeCategory = true; batchEdit.categoryID = category
        Task { await applyBatch(delete: false) }
    }
    private var batchEditorContents: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Only enabled fields will change for the \(selection.count) selected stickers.").font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Section {
                    Toggle("Change category", isOn: $batchEdit.changeCategory)
                    if batchEdit.changeCategory { categoryPicker(selection: $batchEdit.categoryID) }
                }
                Section {
                    Toggle("Rename", isOn: $batchEdit.rename)
                    if batchEdit.rename {
                        TextField("Name prefix", text: $batchEdit.namePrefix)
                        Text("Names will be numbered in selection order, for example: Cat 1, Cat 2.").font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }
                Section {
                    Toggle("Change description", isOn: $batchEdit.changeDescription)
                    if batchEdit.changeDescription { TextField("Description (empty clears it)", text: $batchEdit.description, axis: .vertical) }
                }
                Section {
                    Toggle("Change favorite status", isOn: $batchEdit.changeFavorite)
                    if batchEdit.changeFavorite { Toggle("Favorite", isOn: $batchEdit.favorite) }
                }
            }.scrollContentBackground(.hidden).background { Background() }
                .disabled(busy).navigationTitle("Edit selected stickers").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { batchEditor = false }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { Task { await applyBatch(delete: false) } }.disabled(busy || !batchEdit.canApply)
                    }
                }
        }.foregroundStyle(VesperTheme.ink).interactiveDismissDisabled(busy)
    }
    private func saveCategory() async {
        guard !busy else { return }
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            let path = "/api/stickers/categories" + (renamingCategory.map { "/" + $0 } ?? "")
            let result = try await store.api.request(path, method: renamingCategory == nil ? "POST" : "PATCH", body: .object(["name": .string(String(name.prefix(48)))]))
            let category = result["category"]
            guard !category.id.isEmpty else { throw ServiceError(message: "The category was not saved.") }
            categories.removeAll { $0.id == category.id }; categories.append(category)
            if filter != category.id { stickers = []; filter = category.id }
            else { await load() }
            status = "Category saved."
        } catch { status = error.localizedDescription }
    }
    private func deleteCategory() async {
        guard !busy, let id = deletingCategoryID, categories.contains(where: { $0.id == id }) else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await store.api.request("/api/stickers/categories/" + id, method: "DELETE")
            guard result["deleted"].bool else { throw ServiceError(message: "The category deletion was not confirmed.") }
            deletingCategoryID = nil
            categories.removeAll { $0.id == id }
            stickers = []
            selection = []
            selecting = false
            filter = "all"
            status = "Category deleted. Its stickers are in Uncategorized."
            await load()
        } catch { status = error.localizedDescription }
    }
    private func applyBatch(delete: Bool) async {
        guard !busy, !selection.isEmpty, delete || batchEdit.canApply else { return }
        busy = true; defer { busy = false }
        let result = await StickerBatchOperation.apply(selection, edit: batchEdit, delete: delete, api: store.api)
        selection.removeAll { result.succeeded.contains($0["assetId"].string) }
        batchEditor = false
        status = "\(result.succeeded.count) stickers \(delete ? "deleted" : "updated")."
        if let failure = result.errors.first {
            status += " \(result.errors.count) failed and remain selected. " + failure
        }
        await load()
    }
    private func editor(_ sticker: JSONValue) -> some View {
        NavigationStack {
            Form {
                Group {
                    if let transparentPreview, let image = UIImage(data: transparentPreview) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else { StickerArtwork(sticker: sticker) }
                }.frame(height: 150).frame(maxWidth: .infinity).allowsHitTesting(false)
                    .listRowBackground(Color.clear)
                if removingBackground { ProgressView("Removing background…") }
                if transparentPreview == nil {
                    Button { Task { await removeBackground(sticker) } } label: {
                        Label("Remove background", systemImage: "person.crop.rectangle")
                    }
                } else {
                    Text("Preview · Save creates a new transparent sticker.").font(.caption).foregroundStyle(VesperTheme.muted)
                    Button("Restore original") { transparentPreview = nil }
                }
                TextField("Name", text: $editName)
                TextField("Description", text: $editDescription, axis: .vertical)
                categoryPicker(selection: $editCategory)
                Toggle("Favorite", isOn: $editFavorite)
                if !editError.isEmpty { Text(editError).font(.caption).foregroundStyle(.red) }
                Button("Delete sticker", role: .destructive) { confirmDelete = true }
            }.disabled(saving || removingBackground).navigationTitle("Edit sticker").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { selected = nil }.disabled(saving || removingBackground) }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await saveSticker(delete: false) } }.disabled(saving || removingBackground || editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                .confirmationDialog("Delete this sticker? Existing messages will show an unavailable image.", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await saveSticker(delete: true) } }
                }
        }.presentationDetents([.medium, .large])
            .interactiveDismissDisabled(saving || removingBackground)
    }
    private func removeBackground(_ sticker: JSONValue) async {
        guard !removingBackground else { return }
        removingBackground = true; editError = ""
        defer { removingBackground = false }
        do {
            let data = try await store.api.stickerAssetData(assetID: sticker["assetId"].string)
            transparentPreview = try await Task.detached(priority: .userInitiated) {
                try StickerCutout.makePNG(from: data)
            }.value
        } catch { editError = error.localizedDescription }
    }
    private func saveSticker(delete: Bool) async {
        guard let selected, !saving else { return }
        let assetID = selected.sticker["assetId"].string
        guard !assetID.isEmpty, let encoded = assetID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }
        saving = true; editError = ""; defer { saving = false }
        do {
            if !delete, let transparentPreview {
                let name = (editName.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingPathExtension + ".png"
                let result = try await store.api.uploadFile(transparentPreview, name: name, mime: "image/png", sticker: true, description: editDescription, categoryID: editCategory)
                if editFavorite {
                    _ = try await store.api.request("/api/stickers/" + result["sticker"]["assetId"].string, method: "PATCH", body: .object(["favorite": .bool(true)]))
                }
                self.selected = nil; self.transparentPreview = nil; status = "Transparent sticker saved."
                await load()
                return
            }
            let result = try await store.api.request("/api/stickers/" + encoded, method: delete ? "DELETE" : "PATCH", body: delete ? nil : .object(["name": .string(editName.trimmingCharacters(in: .whitespacesAndNewlines)), "description": .string(editDescription), "categoryId": editCategory.isEmpty ? .null : .string(editCategory), "favorite": .bool(editFavorite)]))
            if !delete { guard result["sticker"]["assetId"].string == assetID else { throw ServiceError(message: "The sticker update was not confirmed.") } }
            self.selected = nil; status = delete ? "Sticker deleted." : "Sticker saved."
            await load()
        } catch { editError = error.localizedDescription }
    }
    private func load() async {
        let id = UUID(); loadID = id
        loading = true; defer { if loadID == id { loading = false } }
        do {
            var components = URLComponents(); components.queryItems = [URLQueryItem(name: "q", value: submittedQuery), URLQueryItem(name: "limit", value: "200")]
            if filter == "favorites" { components.queryItems?.append(URLQueryItem(name: "view", value: "favorites")) }
            else if filter != "all" { components.queryItems?.append(URLQueryItem(name: "category", value: filter)) }
            let result = try await store.api.request("/api/stickers?" + (components.percentEncodedQuery ?? ""))
            guard loadID == id, !Task.isCancelled else { return }
            stickers = result["stickers"].array
            categories = result["categories"].array
        } catch { if loadID == id && !Task.isCancelled { status = error.localizedDescription } }
    }
    private func upload(_ data: Data, name: String, type: UTType) async throws {
        guard data.count <= 16 * 1024 * 1024 else { throw ServiceError(message: "Choose stickers under 16 MB.") }
        if type.conforms(to: .heic) || type.conforms(to: .heif) {
            guard let image = UIImage(data: data), let png = image.pngData() else { throw ServiceError(message: "Could not prepare this image.") }
            _ = try await store.api.uploadFile(png, name: (name as NSString).deletingPathExtension + ".png", mime: "image/png", sticker: true, categoryID: activeCategoryID)
        } else {
            _ = try await store.api.uploadFile(data, name: name, mime: type.preferredMIMEType ?? "application/octet-stream", sticker: true, categoryID: activeCategoryID)
        }
    }
}

struct StickerBatchEdit {
    var changeCategory = false
    var categoryID = ""
    var rename = false
    var namePrefix = ""
    var changeDescription = false
    var description = ""
    var changeFavorite = false
    var favorite = false
    var canApply: Bool {
        (changeCategory || rename || changeDescription || changeFavorite)
            && (!rename || !namePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    func patch(index: Int) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        if changeCategory { fields["categoryId"] = categoryID.isEmpty ? .null : .string(categoryID) }
        if rename { fields["name"] = .string(String(namePrefix.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70)) + " \(index + 1)") }
        if changeDescription { fields["description"] = .string(String(description.prefix(280))) }
        if changeFavorite { fields["favorite"] = .bool(favorite) }
        return .object(fields)
    }
}

enum StickerBatchOperation {
    struct Result {
        var succeeded: Set<String> = []
        var errors: [String] = []
    }
    static func apply(_ stickers: [JSONValue], edit: StickerBatchEdit, delete: Bool, api: APIClient) async -> Result {
        var result = Result()
        guard delete || edit.canApply else { return result }
        for (index, sticker) in stickers.enumerated() {
            let id = sticker["assetId"].string
            do {
                let safeID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
                guard !id.isEmpty, id.unicodeScalars.allSatisfy(safeID.contains) else {
                    throw ServiceError(message: "This sticker is unavailable.")
                }
                let response = try await api.request("/api/stickers/" + id, method: delete ? "DELETE" : "PATCH",
                                                     body: delete ? nil : edit.patch(index: index))
                guard delete ? response["deleted"].bool : response["sticker"]["assetId"].string == id else {
                    throw ServiceError(message: "The sticker change was not confirmed.")
                }
                result.succeeded.insert(id)
            } catch { result.errors.append(sticker["name"].string + ": " + error.localizedDescription) }
        }
        return result
    }
}

enum StickerCutout {
    static func makePNG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ServiceError(message: "Could not read this image.")
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw ServiceError(message: "Background removal works with still images. Import a transparent animation to keep it moving.")
        }
        // Bound memory use and apply EXIF orientation before asking Vision for a mask.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1600]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ServiceError(message: "Could not prepare this image.")
        }
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ServiceError(message: "No subject was found. Try another image, or import a transparent PNG.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: true)
        guard let png = CIContext().pngRepresentation(of: CIImage(cvPixelBuffer: buffer), format: .RGBA8,
                                                       colorSpace: CGColorSpaceCreateDeviceRGB()), png.count <= 16 * 1024 * 1024 else {
            throw ServiceError(message: "Could not save this cutout. Try a smaller image.")
        }
        return png
    }
}

private struct StickerSelection: Identifiable {
    let sticker: JSONValue
    var id: String { sticker["assetId"].string }
}

/// The SwiftUI button owns the whole cell; WebKit only paints the sticker.
struct StickerTile: View {
    let sticker: JSONValue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Rectangle().fill(Color.clear).frame(maxWidth: .infinity).frame(height: 76)
                .overlay { StickerArtwork(sticker: sticker).allowsHitTesting(false).accessibilityHidden(true) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(sticker["description"].string.isEmpty ? sticker["name"].string : sticker["description"].string)
            .accessibilityIdentifier("sticker-" + sticker["assetId"].string)
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
