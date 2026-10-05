import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

private func readingCoverData(from item: PhotosPickerItem?) async -> String? {
    guard let data = try? await item?.loadTransferable(type: Data.self),
          let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
    let size = CGSize(width: 300, height: 420)
    let scaled = UIGraphicsImageRenderer(size: size).jpegData(withCompressionQuality: 0.72) { _ in
        let scale = max(size.width / image.size.width, size.height / image.size.height)
        image.draw(in: CGRect(x: (size.width - image.size.width * scale) / 2,
                              y: (size.height - image.size.height * scale) / 2,
                              width: image.size.width * scale, height: image.size.height * scale))
    }
    return "data:image/jpeg;base64," + scaled.base64EncodedString()
}

struct ReadingRoomView: View {
    @EnvironmentObject private var store: AppStore
    @State private var adding = false
    @State private var importing = false
    @State private var importStatus = ""
    @State private var fileName = ""
    @State private var title = ""
    @State private var text = ""
    @State private var cover = ""
    @State private var coverItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("我们的书架").font(.system(size: 25, weight: .semibold, design: .serif))
                        Text("选一本书，接着读。").font(.subheadline).foregroundStyle(VesperTheme.muted)
                    }
                    Spacer()
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44).vesperGlass(in: Circle(), interactive: true)
                    }.accessibilityLabel("Add a book")
                }
                let books = store.document("readingRoom").array
                if books.isEmpty { EmptyCard(title: "书架还是空的", message: "导入 TXT、Markdown 或可复制文字的 PDF。") }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 24) {
                    ForEach(books) { book in
                        NavigationLink { ReaderView(bookID: book.id) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                ReadingBookCover(title: book["title"].string, cover: book["cover"].string)
                                    .aspectRatio(0.72, contentMode: .fit)
                                Text(book["title"].string.replacingOccurrences(of: "_", with: " "))
                                    .font(.system(size: 14, weight: .medium)).lineLimit(2)
                                Text("继续阅读 · \(book["notes"].array.count) 条批注")
                                    .font(.caption2).foregroundStyle(VesperTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            PhotosPicker(selection: Binding<PhotosPickerItem?>(get: { nil }, set: { item in
                                Task {
                                    guard let cover = await readingCoverData(from: item) else { return }
                                    _ = await store.mutate("readingRoom") { current in
                                        .array(current.array.map { row in
                                            guard row.id == book.id else { return row }
                                            var changed = row; changed["cover"] = .string(cover); return changed
                                        })
                                    }
                                }
                            }), matching: .images) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.caption.weight(.semibold)).frame(width: 34, height: 34)
                                    .vesperGlass(in: Circle(), interactive: true)
                            }
                            .buttonStyle(.plain).padding(6)
                            .accessibilityLabel("Change cover for \(book["title"].string)")
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $adding) {
            EditorSheet(title: "Add a book", busy: store.saving, save: {
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.count <= 500000 else { store.error = "Enter a title and text under 500,000 characters."; return }
                Task {
                    if await store.upsert("readingRoom", item: .object([
                        "id": .string(UUID().uuidString), "title": .string(title), "text": .string(text),
                        "cover": .string(cover), "page": .number(0), "notes": .array([])
                    ])) {
                        adding = false; title = ""; text = ""; cover = ""; coverItem = nil
                        fileName = ""; importStatus = ""
                    }
                }
            }) {
                HStack(spacing: 16) {
                    ReadingBookCover(title: title.isEmpty ? "新书" : title, cover: cover)
                        .frame(width: 88, height: 122)
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        Label("Choose cover", systemImage: "photo").frame(minHeight: 44)
                    }
                }
                Button { importing = true } label: { Label("Import book file", systemImage: "doc.badge.plus").frame(minHeight: 44) }
                Text("TXT, Markdown or text-based PDF").font(.caption).foregroundStyle(VesperTheme.muted)
                if !fileName.isEmpty { Text(fileName).font(.subheadline); Text("\(text.count) characters ready to import").font(.caption) }
                if !importStatus.isEmpty { Text(importStatus).font(.caption).foregroundStyle(.red) }
                FormField(label: "Title", text: $title)
                DisclosureGroup("Or paste text") { FormField(label: "Book text", text: $text, multiline: true) }
            }
            .onChange(of: coverItem) { _, item in
                Task {
                    if let selected = await readingCoverData(from: item) { cover = selected }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20 * 1024 * 1024 else { throw ServiceError(message: "Choose a file under 20 MB.") }
                    let imported: String
                    if url.pathExtension.lowercased() == "pdf" {
                        guard let pdf = PDFDocument(url: url), !pdf.isLocked, let value = pdf.string,
                              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw ServiceError(message: "This PDF has no readable text. Scanned or locked PDFs need a text version.")
                        }
                        imported = value
                    } else {
                        let data = try Data(contentsOf: url)
                        guard let value = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                            throw ServiceError(message: "Save the text file as UTF-8 and import again.")
                        }
                        imported = value
                    }
                    guard !imported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          imported.count <= 500000 else { throw ServiceError(message: "Import a nonempty book under 500,000 characters; split larger books into volumes.") }
                    text = imported; title = url.deletingPathExtension().lastPathComponent
                    fileName = url.lastPathComponent; importStatus = ""
                } catch { importStatus = error.localizedDescription }
            }
        }
    }
}

private struct ReadingBookCover: View {
    let title: String
    let cover: String
    private var palette: [Color] {
        let sets: [[Color]] = [[Color(red: 0.23, green: 0.34, blue: 0.48), Color(red: 0.53, green: 0.68, blue: 0.71)],
                               [Color(red: 0.48, green: 0.30, blue: 0.37), Color(red: 0.77, green: 0.62, blue: 0.55)],
                               [Color(red: 0.25, green: 0.38, blue: 0.33), Color(red: 0.62, green: 0.72, blue: 0.58)],
                               [Color(red: 0.37, green: 0.32, blue: 0.52), Color(red: 0.68, green: 0.65, blue: 0.77)]]
        return sets[title.unicodeScalars.reduce(0) { $0 + Int($1.value) } % sets.count]
    }
    var body: some View {
        ZStack {
            if let comma = cover.firstIndex(of: ","),
               let data = Data(base64Encoded: String(cover[cover.index(after: comma)...])),
               let image = UIImage(data: data) {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 16) {
                    Rectangle().fill(.white.opacity(0.6)).frame(width: 28, height: 1)
                    Text(title.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 19, weight: .medium, design: .serif))
                        .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.75)
                        .foregroundStyle(.white).padding(.horizontal, 13)
                    Rectangle().fill(.white.opacity(0.6)).frame(width: 28, height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 5)
        .accessibilityLabel(title)
    }
}

struct ReadingChapter {
    let title: String
    let range: NSRange
}
struct ReadingPage: Identifiable {
    let id: Int
    let chapter: Int
    let range: NSRange
    let text: String
}
enum ReadingLayout {
    static var attributes: [NSAttributedString.Key: Any] { attributes(fontSize: 18) }
    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 4
        return [.font: UIFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph, .foregroundColor: UIColor.label]
    }
    static func chapters(in source: String) -> [ReadingChapter] {
        let ns = source as NSString
        let pattern = "(?m)^(?:#{1,3}[^\\n]+|第[一二三四五六七八九十百千〇零0-9]+[章节卷篇][^\\n]*|Chapter[ \\t]+[0-9IVXivx]+[^\\n]*)$"
        let matches = (try? NSRegularExpression(pattern: pattern)).map {
            $0.matches(in: source, range: NSRange(location: 0, length: ns.length))
        } ?? []
        let starts = [0] + matches.map(\.range.location).filter { $0 > 0 }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1] : ns.length
            let heading = matches.first(where: { $0.range.location == start }).map { ns.substring(with: $0.range) }
            return ReadingChapter(title: heading ?? (matches.isEmpty ? "全文" : "开篇"),
                                  range: NSRange(location: start, length: end - start))
        }.filter { $0.range.length > 0 }
    }
    static func pages(in source: String, width: CGFloat, height: CGFloat, fontSize: CGFloat = 18) -> (chapters: [ReadingChapter], pages: [ReadingPage]) {
        let chapters = chapters(in: source)
        let ns = source as NSString
        var pages: [ReadingPage] = []
        for (chapterIndex, chapter) in chapters.enumerated() {
            let storage = NSTextStorage(string: ns.substring(with: chapter.range), attributes: attributes(fontSize: fontSize))
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            let container = NSTextContainer(size: CGSize(width: max(1, width), height: max(1, height)))
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let measurement = UITextView(usingTextLayoutManager: false)
            measurement.textContainerInset = .zero
            measurement.textContainer.lineFragmentPadding = 0
            measurement.frame = CGRect(x: 0, y: 0, width: width, height: height)
            var offset = 0
            while storage.length > 0 {
                // Each page is rendered by its own text view, so lay out a fresh first line too.
                let glyphs = manager.glyphRange(for: container)
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                var length = min(storage.length, max(1, NSMaxRange(characters)))
                // A standalone page can wrap differently at its final line. Verify with the renderer.
                while length > 1 {
                    measurement.attributedText = NSAttributedString(string: (storage.string as NSString).substring(to: length),
                                                                   attributes: attributes(fontSize: fontSize))
                    let layout = measurement.layoutManager
                    layout.ensureLayout(for: measurement.textContainer)
                    if layout.usedRect(for: measurement.textContainer).maxY <= height { break }
                    var fittingEnd = 0
                    layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, glyphs, stop in
                        if rect.maxY > height { stop.pointee = true; return }
                        fittingEnd = NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
                    }
                    length = max(1, min(length - 1, fittingEnd))
                }
                let range = NSRange(location: chapter.range.location + offset, length: length)
                pages.append(ReadingPage(id: pages.count, chapter: chapterIndex,
                                         range: range, text: ns.substring(with: range)))
                storage.deleteCharacters(in: NSRange(location: 0, length: length))
                offset += length
            }
        }
        return (chapters, pages)
    }
}

private struct ReadingNoteTarget: Identifiable {
    let id = UUID()
    let range: NSRange?
    let quote: String
}

struct ReaderView: View {
    let bookID: String
    @EnvironmentObject private var store: AppStore
    @State private var chapters: [ReadingChapter] = []
    @State private var pages: [ReadingPage] = []
    @State private var pageIndex = 0
    @State private var progressSave: Task<Void, Never>?
    @State private var target: ReadingNoteTarget?
    @State private var draft = ""
    @State private var showContents = false
    @AppStorage("readingFontSize") private var fontSize = 18.0
    private var book: JSONValue { store.document("readingRoom").array.first { $0.id == bookID } ?? .null }
    private var chapterIndex: Int { pages.indices.contains(pageIndex) ? pages[pageIndex].chapter : 0 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                // Pagination and rendering share the exact same text rectangle.
                let textWidth = floor(max(1, min(viewport.size.width, 720) - 48))
                let textHeight = floor(max(1, viewport.size.height - 24))
                ZStack {
                    if pages.isEmpty { ProgressView("正在排版…") }
                    else {
                        TabView(selection: $pageIndex) {
                            ForEach(pages) { page in
                                ReadingTextPage(page: page, source: book["text"].string, notes: book["notes"].array, fontSize: fontSize) { range, quote in
                                    draft = ""; target = ReadingNoteTarget(range: range, quote: quote)
                                }
                                .frame(width: textWidth, height: textHeight, alignment: .topLeading)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .tag(page.id)
                            }
                        }.tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .task(id: "\(bookID)-\(Int(textWidth))-\(Int(textHeight))-\(fontSize)-\(book["text"].string.utf16.count)") {
                    guard textWidth > 1, textHeight > 1 else { return }
                    let currentLocation = pages.indices.contains(pageIndex) ? pages[pageIndex].range.location : nil
                    let location: Int
                    if let currentLocation { location = currentLocation }
                    else if case .number(let saved) = book["location"] { location = max(0, Int(saved)) }
                    else { location = max(0, Int(book["page"].number) * 1800) }
                    let result = ReadingLayout.pages(in: book["text"].string, width: textWidth, height: textHeight, fontSize: fontSize)
                    chapters = result.chapters; pages = result.pages
                    pageIndex = result.pages.firstIndex { NSLocationInRange(location, $0.range) } ?? max(0, result.pages.count - 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                Button { turn(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(pageIndex == 0).accessibilityLabel("上一页")
                Button { showContents = true } label: {
                    VStack(spacing: 3) {
                        Text(chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : "全文")
                            .lineLimit(1)
                        Text("\(pages.isEmpty ? 0 : pageIndex + 1) / \(pages.count)").monospacedDigit()
                    }.font(.caption).frame(maxWidth: .infinity)
                }.accessibilityLabel("目录与进度，第 \(pageIndex + 1) 页，共 \(pages.count) 页")
                Button { turn(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(pageIndex + 1 >= pages.count).accessibilityLabel("下一页")
            }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(book["title"].string.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("字号", selection: $fontSize) {
                        ForEach([16.0, 18, 20, 22, 24], id: \.self) { size in
                            Text("\(Int(size)) 号").tag(size)
                        }
                    }
                } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel("阅读字号")
                Button { draft = ""; target = ReadingNoteTarget(range: nil, quote: "") } label: {
                    Image(systemName: "text.bubble")
                }.accessibilityLabel("我和 Rowan 的批注")
            }
        }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                List {
                    Section("目录") {
                        ForEach(chapters.indices, id: \.self) { index in
                            Button {
                                if let first = pages.first(where: { $0.chapter == index }) { pageIndex = first.id }
                                showContents = false
                            } label: {
                                HStack {
                                    Text(chapters[index].title).foregroundStyle(.primary)
                                    Spacer()
                                    if index == chapterIndex { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    if pages.count > 1 {
                        Section("阅读进度 · 第 \(pageIndex + 1) / \(pages.count) 页") {
                            Slider(value: Binding(get: { Double(pageIndex) }, set: { pageIndex = Int($0) }),
                                   in: 0...Double(pages.count - 1), step: 1)
                                .accessibilityLabel("阅读进度")
                        }
                    }
                }
                .navigationTitle("目录与进度").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showContents = false } } }
            }.presentationDetents([.medium, .large])
        }
            .onChange(of: pageIndex) { _, next in
                guard pages.indices.contains(next) else { return }
                let location = pages[next].range.location
                progressSave?.cancel()
                progressSave = Task {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    _ = await store.mutate("readingRoom") { current in
                        .array(current.array.map { item in
                            guard item.id == bookID else { return item }
                            var changed = item
                            changed["page"] = .number(Double(next))
                            changed["location"] = .number(Double(location))
                            return changed
                        })
                    }
                }
            }
            .sheet(item: $target) { selection in
                ReadingNoteSheet(target: selection, bookID: bookID, bookTitle: book["title"].string, notes: notes(for: selection), draft: $draft,
                                 saving: store.saving) { saveNote(for: selection) }
                    .presentationDetents([.medium, .large])
            }
    }
    private func turn(_ direction: Int) { pageIndex = min(max(0, pageIndex + direction), max(0, pages.count - 1)) }
    private func notes(for selection: ReadingNoteTarget) -> [JSONValue] {
        book["notes"].array.filter { entry in
            guard let range = selection.range else { return true }
            guard let span = ReadingTextPage.range(for: entry, in: book["text"].string) else { return false }
            return NSIntersectionRange(range, span).length > 0
        }
    }
    private func saveNote(for selection: ReadingNoteTarget) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var fields: [String: JSONValue] = [
            "id": .string(UUID().uuidString), "page": .number(Double(pageIndex)),
            "quote": .string(selection.quote), "text": .string(value),
            "author": .string("Vera"), "date": .string(isoNow())
        ]
        if let range = selection.range {
            fields["rangeStart"] = .number(Double(range.location))
            fields["rangeLength"] = .number(Double(range.length))
        }
        let entry = JSONValue.object(fields)
        Task {
            let saved = await store.mutate("readingRoom") { current in
                .array(current.array.map { item in
                    guard item.id == bookID else { return item }
                    var changed = item; changed["notes"] = .array(item["notes"].array + [entry]); return changed
                })
            }
            if saved { draft = ""; target = nil }
        }
    }
}

private struct ReadingNoteSheet: View {
    let target: ReadingNoteTarget
    let bookID: String
    let bookTitle: String
    @State private var bookmark = false
    let notes: [JSONValue]
    @Binding var draft: String
    let saving: Bool
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !target.quote.isEmpty {
                        Text(target.quote).font(.system(.body, design: .serif)).italic()
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                        Button { bookmark = true } label: { Label("存到书签", systemImage: "bookmark") }
                    }
                    if notes.isEmpty {
                        Text("还没有批注，留下第一段共读心情吧。").foregroundStyle(.secondary)
                    }
                    ForEach(notes) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(entry["author"].string.isEmpty ? "批注" : entry["author"].string, systemImage: "pencil.line")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(entry["author"].string == "Rowan" ? Color.teal : Color.orange)
                            if target.range == nil && !entry["quote"].string.isEmpty {
                                Text(entry["quote"].string).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry["text"].string).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                    Text("我的批注").font(.headline)
                    TextEditor(text: $draft).frame(minHeight: 95)
                        .scrollContentBackground(.hidden)
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    Text("橙色是你的批注，青色是 Rowan 的批注。选中同一段文字，可以接着写。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("保存批注", action: save).buttonStyle(VesperGlassButtonStyle())
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }.padding(20)
            }
            .navigationTitle(target.range == nil ? "全文批注" : "划线批注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $bookmark) { BookmarkEditor(quote: target.quote, bookID: bookID, sourceTitle: bookTitle) }
    }
}

struct ReadingTextPage: UIViewRepresentable {
    let page: ReadingPage
    let source: String
    let notes: [JSONValue]
    var fontSize: CGFloat = 18
    let openNote: (NSRange, String) -> Void

    static func range(for entry: JSONValue, in source: String) -> NSRange? {
        let ns = source as NSString
        if case .number(let start) = entry["rangeStart"], case .number(let length) = entry["rangeLength"] {
            let range = NSRange(location: Int(start), length: Int(length))
            if range.length > 0 && NSMaxRange(range) <= ns.length { return range }
        }
        let quote = entry["quote"].string
        guard !quote.isEmpty else { return nil }
        // Older notes stored a quote and an 1,800-unit page number, but no exact offset.
        let anchor = min(Int(entry["page"].number) * 1800, ns.length)
        let near = NSRange(location: anchor, length: min(1800, ns.length - anchor))
        let found = ns.range(of: quote, range: near)
        return found.location != NSNotFound ? found : {
            let anywhere = ns.range(of: quote)
            return anywhere.location == NSNotFound ? nil : anywhere
        }()
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.textContainer.widthTracksTextView = true
        view.delegate = context.coordinator
        view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: UIColor.label]
        view.accessibilityHint = "左右滑动翻页；长按选择文字后可添加批注，点划线查看批注。"
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.page = page
        context.coordinator.openNote = openNote
        context.coordinator.source = source
        let styled = NSMutableAttributedString(string: page.text, attributes: ReadingLayout.attributes(fontSize: fontSize))
        for entry in notes {
            guard let span = Self.range(for: entry, in: source) else { continue }
            let intersection = NSIntersectionRange(span, page.range)
            guard intersection.length > 0 else { continue }
            let local = NSRange(location: intersection.location - page.range.location, length: intersection.length)
            let color: UIColor = entry["author"].string == "Rowan" ? .systemTeal : .systemOrange
            styled.addAttributes([.backgroundColor: color.withAlphaComponent(0.12),
                                  .underlineStyle: NSUnderlineStyle.single.rawValue,
                                  .underlineColor: color,
                                  .link: URL(string: "vesper-reading-note://note/\(span.location)")!], range: local)
        }
        if !view.attributedText.isEqual(to: styled) { view.attributedText = styled }
    }
    func makeCoordinator() -> Coordinator { Coordinator(page: page, source: source, openNote: openNote) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var page: ReadingPage
        var source: String
        var openNote: (NSRange, String) -> Void
        init(page: ReadingPage, source: String, openNote: @escaping (NSRange, String) -> Void) {
            self.page = page; self.source = source; self.openNote = openNote
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, NSMaxRange(range) <= (page.text as NSString).length else { return nil }
            let action = UIAction(title: "批注", image: UIImage(systemName: "pencil.line")) { [weak self] _ in
                guard let self else { return }
                let whole = NSRange(location: self.page.range.location + range.location, length: range.length)
                self.openNote(whole, (self.source as NSString).substring(with: whole))
            }
            return UIMenu(children: [action] + suggestedActions)
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme == "vesper-reading-note", let start = Int(URL.lastPathComponent),
                  let note = textView.attributedText.attribute(.link, at: characterRange.location, effectiveRange: nil) as? URL,
                  note == URL else { return false }
            let sourceText = source as NSString
            let whole = NSRange(location: page.range.location + characterRange.location, length: characterRange.length)
            guard NSMaxRange(whole) <= sourceText.length else { return false }
            // Use the link's starting offset to include every annotation on the same passage.
            let matching = NSRange(location: start, length: max(1, NSMaxRange(whole) - start))
            guard NSMaxRange(matching) <= sourceText.length else { return false }
            openNote(matching, sourceText.substring(with: matching))
            return false
        }
    }
}
