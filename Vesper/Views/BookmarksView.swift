import SwiftUI

struct BookmarksView: View {
    @EnvironmentObject private var store: AppStore
    @State private var cards: [JSONValue] = []
    @State private var cursor = ""
    @State private var loading = false
    @State private var status = ""
    @State private var adding = false
    @State private var selected: String?
    @State private var deleting: JSONValue?
    @Environment(\.scenePhase) private var phase
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("书签").font(.system(size: 26, design: .serif))
                Spacer()
                Button { Task { await load(reset: true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading).accessibilityLabel("Refresh bookmarks")
                Button { adding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("Add bookmark")
            }.padding(.horizontal, 24)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            if cards.isEmpty {
                Spacer()
                if loading { ProgressView() }
                else { EmptyCard(title: "留下一句想珍藏的话", message: "你和 Rowan 的文字，或共读时遇到的一段话。") }
                Spacer()
            } else {
                GeometryReader { bounds in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 18) {
                            ForEach(cards) { card in
                                BookmarkCard(card: card)
                                    .frame(width: min(440, bounds.size.width * 0.82), height: bounds.size.height - 24)
                                    .id(card.id)
                                    .contextMenu {
                                        ShareLink(item: card["text"].string + "\n— " + card["source"].string)
                                        Button("Delete", role: .destructive) { deleting = card }
                                    }
                            }
                        }.scrollTargetLayout().padding(.vertical, 8)
                    }.contentMargins(.horizontal, max(0, (bounds.size.width - min(440, bounds.size.width * 0.82)) / 2))
                        .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                        .scrollPosition(id: $selected)
                }
                if !cursor.isEmpty { Button(loading ? "Loading…" : "更早的书签") { Task { await load(reset: false) } }.disabled(loading) }
                Text("左右滑动翻阅 · 长按分享").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 16).padding(.bottom, 12)
        .task { await load(reset: true) }
        .onChange(of: phase) { _, value in if value == .active { Task { await load(reset: true) } } }
        .sheet(isPresented: $adding, onDismiss: { Task { await load(reset: true) } }) { BookmarkEditor() }
        .confirmationDialog("Delete this bookmark?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                guard let card = deleting else { return }
                Task {
                    do {
                        let result = try await store.api.request("/api/bookmarks?id=\(card.id)", method: "DELETE")
                        guard result["ok"].bool else { throw ServiceError(message: "Deletion was not confirmed.") }
                        cards.removeAll { $0.id == card.id }; deleting = nil
                    } catch { status = error.localizedDescription }
                }
            }
        }
    }
    private func load(reset: Bool) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "limit", value: "30")]
            if !reset && !cursor.isEmpty { query.queryItems?.append(URLQueryItem(name: "before", value: cursor)) }
            let result = try await store.api.request("/api/bookmarks?" + (query.percentEncodedQuery ?? ""))
            var seen = Set<String>()
            cards = ((reset ? [] : cards) + result["bookmarks"].array).filter { seen.insert($0.id).inserted }
            cursor = result["before"].string; status = ""
        } catch { status = error.localizedDescription }
    }
}

struct BookmarkCard: View {
    let card: JSONValue
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { size in
                if let url = URL(string: card["imageUrl"].string), ChatWebURL.accepts(url), url.scheme == "https" {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Image("DesireCoast").resizable().scaledToFill() }
                    }.frame(width: size.size.width, height: size.size.height).clipped()
                } else { Image("DesireCoast").resizable().scaledToFill().frame(width: size.size.width, height: size.size.height).clipped() }
            }.frame(height: 180)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(card["text"].string).font(.system(size: 22, design: .serif)).lineSpacing(8).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !card["quote"].string.isEmpty && card["quote"].string != card["text"].string {
                        Text("原句：" + card["quote"].string).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(26)
            }
            if !card["source"].string.isEmpty {
                Text("— " + card["source"].string).font(.system(.body, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 24).padding(.vertical, 12)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(card["author"].string + " · " + ChatPresentation.time(card["createdAt"].string)).font(.caption)
                if !card["imageSource"].string.isEmpty { Text("图片 · " + card["imageSource"].string).font(.caption2).lineLimit(2) }
            }.foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(18)
        }.background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 5))
            .clipShape(RoundedRectangle(cornerRadius: 5)).shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

struct BookmarkEditor: View {
    var quote = ""
    var bookID = ""
    var sourceTitle = ""
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var source = ""
    @State private var imageURL = ""
    @State private var imageSource = ""
    @State private var status = ""
    @State private var busy = false
    @State private var identifier = UUID().uuidString
    var body: some View {
        EditorSheet(title: "留下书签", busy: busy, save: save) {
            FormField(label: "文字", text: $text, multiline: true)
            if bookID.isEmpty { FormField(label: "出处（可选）", text: $source) }
            else { Text(sourceTitle).font(.caption).foregroundStyle(.secondary) }
            FormField(label: "图片 HTTPS 地址（可选）", text: $imageURL)
            FormField(label: "图片来源或生成说明（可选）", text: $imageSource)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
        }.onAppear { text = quote; source = sourceTitle }
    }
    private func save() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await store.api.request("/api/bookmarks", method: "POST", body: .object([
                    "id": .string(identifier), "text": .string(text), "source": .string(source), "bookId": .string(bookID),
                    "quote": .string(quote), "imageUrl": .string(imageURL), "imageSource": .string(imageSource)]))
                guard result["bookmark"].id == identifier else { throw ServiceError(message: "Bookmark save was not confirmed.") }
                dismiss()
            } catch { status = error.localizedDescription }
        }
    }
}
