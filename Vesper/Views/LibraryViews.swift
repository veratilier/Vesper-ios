import SwiftUI
import PhotosUI

struct DesireView: View {
    @EnvironmentObject private var store: AppStore
    @State private var state: JSONValue = .null
    @State private var history: [JSONValue] = []
    @State private var status = ""
    private let fields = [("longing", "想念"), ("tenderness", "温柔"), ("playfulness", "玩心"), ("intensity", "浓度"), ("attachment", "依恋"), ("possessiveness", "占有欲")]
    var body: some View {
        Page(title: "Desire", subtitle: "A little more than words.") {
            GlassCard {
                VStack(spacing: 24) {
                    FlowerView(values: fields.map { state[$0.0].number }).padding(.vertical, 20)
                    ForEach(fields, id: \.0) { key, title in
                        HStack { Text(title).font(.subheadline).frame(width: 55, alignment: .leading); ProgressView(value: min(100, max(0, state[key].number)), total: 100).tint(VesperTheme.accent); Text(state == .null ? "—" : String(Int(state[key].number))).font(.caption).monospacedDigit().frame(width: 30) }
                    }
                }
            }
            if !status.isEmpty { Text(status).font(.caption) }
            ForEach(history) { entry in GlassCard { VStack(alignment: .leading, spacing: 8) { Text(entry["note"].string).font(.subheadline).textSelection(.enabled); Text(entry["createdAt"].string).font(.caption).foregroundStyle(VesperTheme.muted) } } }
        }.task { await load() }.refreshable { await load() }
    }
    private func load() async {
        do {
            let response = try await store.api.request("/api/desire"); state = response["data"]
            let h = try await store.api.request("/api/desire?view=history&limit=20"); history = h["data"]["records"].array
            if history.isEmpty { history = h["data"]["history"].array }
            status = ""
        } catch { status = error.localizedDescription }
    }
}
struct MemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var search = ""
    @State private var type = ""
    @State private var status = ""
    @State private var adding = false
    @State private var text = ""
    @State private var busy = false
    var body: some View {
        Page(title: "Memory", subtitle: "Things worth keeping close.") {
            Picker("Type", selection: $type) { Text("All").tag(""); Text("Core").tag("core"); Text("Long-term").tag("long_term"); Text("Feelings").tag("feeling"); Text("Dreams").tag("dream") }.pickerStyle(.menu)
            HStack { TextField("Search memories", text: $search).submitLabel(.search).onSubmit { Task { await load() } }; Button { Task { await load() } } label: { Image(systemName: "magnifyingglass") } }.padding(14).background(.regularMaterial, in: Capsule())
            Button { adding = true } label: { Label("Add core memory", systemImage: "plus") }
            if !status.isEmpty { Text(status).font(.caption) }
            ForEach(items) { item in
                GlassCard { VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(item["type"].string.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(VesperTheme.muted); Spacer(); Button { Task { await pin(item) } } label: { Image(systemName: item["pinned"].bool ? "pin.fill" : "pin") }.disabled(busy) }
                    Text(item["body"].string).font(.subheadline).textSelection(.enabled)
                }}
            }
        }.task { await load() }.onChange(of: type) { _, _ in Task { await load() } }
        .sheet(isPresented: $adding) {
            EditorSheet(title: "Core memory", busy: busy, save: {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { busy = true; defer { busy = false }; do { _ = try await store.api.request("/api/memory", method: "POST", body: .object(["action": .string("create_core"), "body": .string(text)])); adding = false; text = ""; await load() } catch { store.error = error.localizedDescription } }
            }) { FormField(label: "Memory", text: $text, multiline: true) }
        }
    }
    private func load() async {
        do { var query = URLComponents(); query.queryItems = [URLQueryItem(name: "q", value: search), URLQueryItem(name: "type", value: type)]; let r = try await store.api.request("/api/memory?" + (query.percentEncodedQuery ?? "")); items = r["memories"].array; status = items.isEmpty ? "No memories found." : "" }
        catch { status = error.localizedDescription }
    }
    private func pin(_ item: JSONValue) async {
        busy = true; defer { busy = false }
        do { _ = try await store.api.request("/api/memory", method: "PATCH", body: .object(["id": .string(item.id), "action": .string("pin"), "pinned": .bool(!item["pinned"].bool)])); await load() }
        catch { status = error.localizedDescription }
    }
}
struct AlbumView: View {
    @EnvironmentObject private var store: AppStore
    @State private var photos: [JSONValue] = []
    @State private var selected: JSONValue?
    @State private var category = "All"
    @State private var status = ""
    var body: some View {
        Page(title: "Album", subtitle: "Little pieces of our days.") {
            Picker("Album", selection: $category) { Text("All").tag("All"); ForEach(Array(Set(photos.map { $0["category"].string })).sorted(), id: \.self) { Text($0.isEmpty ? "Unsorted" : $0).tag($0) } }.pickerStyle(.menu)
            if !status.isEmpty { Text(status).font(.caption) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(photos.filter { category == "All" || $0["category"].string == category }) { photo in
                    Button { selected = photo } label: {
                        VStack(alignment: .leading) { Artwork(url: photo["url"].string).frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 18)); Text(photo["caption"].string).font(.caption).lineLimit(2) }
                    }.buttonStyle(.plain)
                }
            }
        }.task { await load() }.refreshable { await load() }
        .sheet(item: $selected) { item in
            NavigationStack {
                ZStack { Background(); ScrollView { VStack(spacing: 18) {
                    AsyncImage(url: URL(string: item["url"].string)) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                    Text(item["caption"].string).textSelection(.enabled).padding()
                    if let url = URL(string: item["url"].string) { ShareLink("Share photo", item: url) }
                }.padding() } }.navigationTitle(item["category"].string).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } }
            }
        }
    }
    private func load() async {
        do { let r = try await store.api.request("/api/photos"); photos = r["photos"].array; status = photos.isEmpty ? "No photos in your album yet." : "" }
        catch { status = error.localizedDescription }
    }
}
struct PandoraView: View {
    var body: some View {
        Page(title: "Pandora", subtitle: "Small doors to other worlds.") {
            NavigationLink { ReadingRoomView() } label: {
                GlassCard { HStack(spacing: 16) { Image(systemName: "book.pages").font(.largeTitle); VStack(alignment: .leading, spacing: 7) { Text("Reading Room").font(.headline); Text("Our bookshelf, passages and margins").font(.caption).foregroundStyle(VesperTheme.muted) }; Spacer(); Image(systemName: "chevron.right") } }
            }.buttonStyle(.plain)
            NavigationLink { DesireView() } label: { GlassCard { Label("Desire", systemImage: "heart").font(.headline) } }.buttonStyle(.plain)
        }
    }
}
struct ReadingRoomView: View {
    @EnvironmentObject private var store: AppStore
    @State private var adding = false
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        Page(title: "Reading Room", subtitle: "A quiet place to turn the next page together.") {
            Button { adding = true } label: { Label("Add a book", systemImage: "plus") }
            ForEach(store.document("readingRoom").array) { book in
                NavigationLink { ReaderView(bookID: book.id) } label: { GlassCard { VStack(alignment: .leading, spacing: 10) { Text(book["title"].string).font(.headline); Text("Page \(Int(book["page"].number) + 1) · \(book["notes"].array.count) notes").font(.caption).foregroundStyle(VesperTheme.muted) } } }.buttonStyle(.plain)
            }
        }.sheet(isPresented: $adding) {
            EditorSheet(title: "Add a book", busy: store.saving, save: {
                guard !title.isEmpty, !text.isEmpty, text.count <= 500000 else { store.error = "Enter a title and text under 500,000 characters."; return }
                Task { if await store.upsert("readingRoom", item: .object(["id": .string(UUID().uuidString), "title": .string(title), "text": .string(text), "page": .number(0), "notes": .array([])])) { adding = false; title = ""; text = "" } }
            }) { FormField(label: "Title", text: $title); FormField(label: "Book text", text: $text, multiline: true) }
        }
    }
}
struct ReaderView: View {
    let bookID: String
    @EnvironmentObject private var store: AppStore
    @State private var note = ""
    @State private var quote = ""
    var book: JSONValue { store.document("readingRoom").array.first { $0.id == bookID } ?? .null }
    var pages: [String] {
        // Match the web reader's 1,800 UTF-16 code-unit pagination.
        let units = Array(book["text"].string.utf16)
        return stride(from: 0, to: units.count, by: 1800).map { String(decoding: units[$0..<min($0 + 1800, units.count)], as: UTF16.self) }
    }
    var page: Int { min(max(0, Int(book["page"].number)), max(0, pages.count - 1)) }
    var body: some View {
        Page(title: book["title"].string) {
            HStack { Button("Previous") { turn(page - 1) }.disabled(page == 0 || store.saving); Spacer(); Text("\(page + 1) / \(max(1, pages.count))").font(.caption); Spacer(); Button("Next") { turn(page + 1) }.disabled(page + 1 >= pages.count || store.saving) }
            GlassCard { Text(pages.isEmpty ? "" : pages[page]).font(.system(.body, design: .serif)).lineSpacing(8).textSelection(.enabled) }
            GlassCard { VStack(spacing: 12) { FormField(label: "Passage", text: $quote); FormField(label: "In the margins", text: $note, multiline: true); Button("Save note") { saveNote() }.disabled(note.isEmpty || store.saving) } }
            ForEach(book["notes"].array) { entry in GlassCard { VStack(alignment: .leading, spacing: 8) { Text("\(entry["author"].string) · Page \(Int(entry["page"].number) + 1)").font(.caption); Text(entry["quote"].string).italic(); Text(entry["text"].string).textSelection(.enabled) } } }
        }
    }
    private func turn(_ next: Int) {
        Task { _ = await store.mutate("readingRoom") { current in .array(current.array.map { item in guard item.id == bookID else { return item }; var changed = item; changed["page"] = .number(Double(next)); return changed }) } }
    }
    private func saveNote() {
        let entry: JSONValue = .object(["id": .string(UUID().uuidString), "page": .number(Double(page)), "quote": .string(quote), "text": .string(note), "author": .string("Vera"), "date": .string(isoNow())])
        Task { let saved = await store.mutate("readingRoom") { current in .array(current.array.map { item in guard item.id == bookID else { return item }; var changed = item; changed["notes"] = .array(item["notes"].array + [entry]); return changed }) }; if saved { note = ""; quote = "" } }
    }
}
