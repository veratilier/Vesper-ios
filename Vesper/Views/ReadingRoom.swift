import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

private func readingCoverData(from item: PhotosPickerItem?) async -> String? {
    guard let data = try? await item?.loadTransferable(type: Data.self) else { return nil }
    return readingCoverData(from: data)
}

private func readingCoverData(from data: Data) -> String? {
    guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
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
    @State private var editingBook: JSONValue?
    @State private var deletingBook: JSONValue?

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
                            .frame(width: 44, height: 44).vesperMaterial(.regularMaterial, in: Circle())
                    }.accessibilityLabel("Add a book")
                }
                let books = store.document("readingRoom").array
                if books.isEmpty { EmptyCard(title: "书架还是空的", message: "导入 EPUB、TXT、Markdown 或可复制文字的 PDF。") }
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
                        .contextMenu {
                            Button { editingBook = book } label: { Label("Edit book", systemImage: "pencil") }
                            Button(role: .destructive) { deletingBook = book } label: { Label("Delete book", systemImage: "trash") }
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
                Text("EPUB, TXT, Markdown or text-based PDF").font(.caption).foregroundStyle(VesperTheme.muted)
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
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "epub") ?? .data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 20 * 1024 * 1024 else { throw ServiceError(message: "Choose a file under 20 MB.") }
                    let imported: String
                    if url.pathExtension.lowercased() == "epub" {
                        let book = try EPUBImporter.load(url)
                        imported = book.text
                        title = book.title
                        if let coverData = book.cover, let importedCover = readingCoverData(from: coverData) { cover = importedCover }
                    } else if url.pathExtension.lowercased() == "pdf" {
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
                    text = imported
                    if url.pathExtension.lowercased() != "epub" { title = url.deletingPathExtension().lastPathComponent }
                    fileName = url.lastPathComponent; importStatus = ""
                } catch { importStatus = error.localizedDescription }
            }
        }
        .sheet(item: $editingBook) { book in
            ReadingBookDetailsSheet(book: book).environmentObject(store)
        }
        .confirmationDialog("Delete this book?", isPresented: Binding(
            get: { deletingBook != nil }, set: { if !$0 { deletingBook = nil } }
        ), presenting: deletingBook) { book in
            Button("Delete book", role: .destructive) {
                Task {
                    _ = await store.mutate("readingRoom") { current in
                        .array(current.array.filter { $0.id != book.id })
                    }
                    deletingBook = nil
                }
            }
        } message: { _ in
            Text("The book, reading progress and its notes will be removed from your Library.")
        }
    }

}

private struct ReadingBookDetailsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let book: JSONValue
    @State private var title: String
    @State private var cover: String
    @State private var coverItem: PhotosPickerItem?
    @State private var loadingCover = false

    init(book: JSONValue) {
        self.book = book
        _title = State(initialValue: book["title"].string)
        _cover = State(initialValue: book["cover"].string)
    }

    var body: some View {
        EditorSheet(title: "Edit book", busy: store.saving || loadingCover, save: {
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { store.error = "Enter a book title."; return }
            Task {
                let saved = await store.mutate("readingRoom") { current in
                    .array(current.array.map { row in
                        guard row.id == book.id else { return row }
                        var changed = row
                        changed["title"] = .string(cleaned)
                        changed["cover"] = .string(cover)
                        return changed
                    })
                }
                if saved { dismiss() }
            }
        }) {
            ReadingBookCover(title: title.isEmpty ? "Book" : title, cover: cover)
                .frame(width: 112, height: 156)
            PhotosPicker(selection: $coverItem, matching: .images) {
                Label("Change cover", systemImage: "photo").frame(minHeight: 44)
            }
            if !cover.isEmpty {
                Button("Remove cover") { cover = "" }
                    .foregroundStyle(VesperTheme.muted)
            }
            FormField(label: "Book title", text: $title)
        }
        .onChange(of: coverItem) { _, item in
            loadingCover = true
            Task {
                if let selected = await readingCoverData(from: item) { cover = selected }
                loadingCover = false
            }
        }
    }
}

struct ReadingBookCover: View {
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
            if Task.isCancelled { return ([], []) }
            let storage = NSTextStorage(string: ns.substring(with: chapter.range), attributes: attributes(fontSize: fontSize))
            let manager = NSLayoutManager()
            storage.addLayoutManager(manager)
            var offset = 0
            while offset < storage.length {
                if Task.isCancelled { return ([], []) }
                // Lay out the chapter once across successive containers. Removing
                // text from the front and remeasuring every page made long books
                // block the main thread for minutes on iPhone.
                // UITextView can add the final paragraph's spacing when it lays out
                // a page independently. Reserve that space to avoid clipping.
                let container = NSTextContainer(size: CGSize(width: max(1, width), height: max(1, height - 8)))
                container.lineFragmentPadding = 0
                manager.addTextContainer(container)
                let glyphs = manager.glyphRange(for: container)
                let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let length = max(1, min(storage.length - offset, NSMaxRange(characters) - offset))
                let range = NSRange(location: chapter.range.location + offset, length: length)
                pages.append(ReadingPage(id: pages.count, chapter: chapterIndex,
                                         range: range, text: ns.substring(with: range)))
                offset += length
            }
        }
        return (chapters, pages)
    }
}

struct ReadingNoteTarget: Identifiable {
    let id = UUID()
    let range: NSRange?
    let quote: String
}

enum ReadingAnnotation {
    static func create(range: NSRange?, quote: String, text: String, page: Int) -> JSONValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: JSONValue] = [
            "id": .string(UUID().uuidString), "page": .number(Double(page)),
            "quote": .string(quote), "text": .string(value), "kind": .string(value.isEmpty ? "highlight" : "note"),
            "author": .string("Vera"), "date": .string(isoNow())
        ]
        if let range {
            fields["rangeStart"] = .number(Double(range.location))
            fields["rangeLength"] = .number(Double(range.length))
        }
        return .object(fields)
    }
    static func isHighlight(_ entry: JSONValue) -> Bool {
        entry["kind"].string == "highlight" ||
        (entry["text"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry["rangeStart"] != .null)
    }
    static func edited(_ entry: JSONValue, text: String) -> JSONValue {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = entry
        updated["text"] = .string(value)
        updated["kind"] = .string(value.isEmpty ? "highlight" : "note")
        updated["editedAt"] = .string(isoNow())
        return updated
    }
}

struct ReaderView: View {
    let bookID: String
    @AppStorage("vesperLastReadBook") private var lastReadBook = ""
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
        let currentBook = book
        let sourceText = currentBook["text"].string
        let currentNotes = currentBook["notes"].array
        return VStack(spacing: 0) {
            GeometryReader { viewport in
                // Pagination and rendering share the exact same text rectangle.
                let textWidth = floor(max(1, min(viewport.size.width, 720) - 48))
                let textHeight = floor(max(1, viewport.size.height - 24))
                ZStack {
                    if pages.isEmpty { ProgressView("正在排版…") }
                    else {
                        TabView(selection: $pageIndex) {
                            ForEach(pages) { page in
                                ReadingTextPage(page: page, source: sourceText, notes: currentNotes, fontSize: fontSize,
                                                openNote: { range, quote in
                                                    draft = ""; target = ReadingNoteTarget(range: range, quote: quote)
                                                }, highlight: { range, quote in
                                                    Task { await saveNote(for: ReadingNoteTarget(range: range, quote: quote), highlightOnly: true) }
                                                })
                                .frame(width: textWidth, height: textHeight, alignment: .topLeading)
                                .padding(.horizontal, 24).padding(.vertical, 12)
                                .frame(width: viewport.size.width, height: viewport.size.height)
                                .tag(page.id)
                            }
                        }.tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .task(id: ReadingLayoutKey(bookID: bookID, width: Int(textWidth), height: Int(textHeight), fontSize: fontSize, text: sourceText)) {
                    guard textWidth > 1, textHeight > 1 else { return }
                    let currentLocation = pages.indices.contains(pageIndex) ? pages[pageIndex].range.location : nil
                    let location: Int
                    if let currentLocation { location = currentLocation }
                    else if case .number(let saved) = currentBook["location"] { location = max(0, Int(saved)) }
                    else { location = max(0, Int(currentBook["page"].number) * 1800) }
                    let requestedFontSize = fontSize
                    let work = Task.detached(priority: .userInitiated) {
                        ReadingLayout.pages(in: sourceText, width: textWidth, height: textHeight, fontSize: requestedFontSize)
                    }
                    let result = await withTaskCancellationHandler {
                        await work.value
                    } onCancel: { work.cancel() }
                    guard !Task.isCancelled else { return }
                    let latestLocation = pages.indices.contains(pageIndex) ? pages[pageIndex].range.location : location
                    chapters = result.chapters; pages = result.pages
                    pageIndex = result.pages.firstIndex { NSLocationInRange(latestLocation, $0.range) } ?? max(0, result.pages.count - 1)
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
        .navigationTitle(currentBook["title"].string.replacingOccurrences(of: "_", with: " "))
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
                }.accessibilityLabel("我和 \(store.agentDisplayName) 的批注")
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
            .onAppear { lastReadBook = bookID }
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
                ReadingNoteSheet(store: store, target: selection, bookID: bookID, bookTitle: currentBook["title"].string, notes: notes(for: selection), draft: $draft,
                                 saving: store.saving, save: { await saveNote(for: selection) },
                                 highlight: { await saveNote(for: selection, highlightOnly: true) },
                                 edit: { id, text in await editNote(id: id, text: text) })
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
    private func saveNote(for selection: ReadingNoteTarget, highlightOnly: Bool = false) async {
        let value = highlightOnly ? "" : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty || (highlightOnly && selection.range != nil) else { return }
        if highlightOnly, let range = selection.range,
           book["notes"].array.contains(where: { note in
               note["author"].string == "Vera" &&
               Int(note["rangeStart"].number) == range.location && Int(note["rangeLength"].number) == range.length
           }) {
            target = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        let entry = ReadingAnnotation.create(range: selection.range, quote: selection.quote, text: value, page: pageIndex)
        let saved = await store.mutate("readingRoom") { current in
            .array(current.array.map { item in
                guard item.id == bookID else { return item }
                var changed = item; changed["notes"] = .array(item["notes"].array + [entry]); return changed
            })
        }
        if saved {
            if !highlightOnly { draft = "" }
            target = nil
            if highlightOnly { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
    private func editNote(id: String, text: String) async -> Bool {
        guard let original = book["notes"].array.first(where: { $0.id == id && $0["author"].string == "Vera" }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ReadingAnnotation.isHighlight(original) || original["rangeStart"] != .null else { return false }
        let saved = await store.mutate("readingRoom") { current in
            .array(current.array.map { item in
                guard item.id == bookID else { return item }
                var changed = item
                changed["notes"] = .array(item["notes"].array.map { note in
                    guard note.id == id, note["author"].string == "Vera" else { return note }
                    return ReadingAnnotation.edited(note, text: text)
                })
                return changed
            })
        }
        return saved
    }
}

private struct ReadingLayoutKey: Equatable {
    let bookID: String
    let width: Int
    let height: Int
    let fontSize: Double
    let text: String
}

struct ReadingNoteSheet: View {
    let store: AppStore
    let target: ReadingNoteTarget
    let bookID: String
    let bookTitle: String
    @State private var bookmark = false
    let notes: [JSONValue]
    @Binding var draft: String
    let saving: Bool
    let save: () async -> Void
    let highlight: () async -> Void
    let edit: (String, String) async -> Bool
    @State private var isSaving = false
    @State private var editingID: String?
    @State private var editDraft = ""
    @State private var editSaving = false
    @State private var displayedNotes: [JSONValue]?
    @Environment(\.dismiss) private var dismiss
    private var visibleNotes: [JSONValue] { displayedNotes ?? notes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !target.quote.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("选中的文字", systemImage: "text.quote").font(.caption.weight(.semibold))
                                Spacer()
                                Button { bookmark = true } label: { Label("书签", systemImage: "bookmark") }
                                    .font(.caption)
                            }.foregroundStyle(.secondary)
                            Text(target.quote).font(.system(.body, design: .serif))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                    }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("已有记录").font(.headline)
                            Spacer()
                            Text("\(visibleNotes.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        if visibleNotes.isEmpty {
                            Text("这段还没有记录。").font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                        ForEach(visibleNotes) { entry in noteCard(entry) }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text(target.range == nil ? "写给这本书" : "写下批注").font(.headline)
                        ZStack(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("写点什么…").foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13).padding(.vertical, 15).allowsHitTesting(false)
                            }
                            TextEditor(text: $draft).frame(minHeight: 96)
                                .scrollContentBackground(.hidden).padding(8)
                        }
                        .vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        HStack(spacing: 12) {
                            if target.range != nil {
                                Button("只划线") {
                                    isSaving = true
                                    Task { await highlight(); isSaving = false }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || isSaving)
                            }
                            Spacer()
                            Button {
                                isSaving = true
                                Task { await save(); isSaving = false }
                            } label: {
                                if isSaving { ProgressView().controlSize(.small) }
                                else { Text("保存批注") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || isSaving)
                        }
                    }
                }.padding(20)
            }
            .navigationTitle(target.range == nil ? "全书笔记" : "划线与批注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented: $bookmark) { BookmarkEditor(quote: target.quote, bookID: bookID, sourceTitle: bookTitle).environmentObject(store) }
    }

    private func noteCard(_ entry: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(entry["author"].string.isEmpty ? "批注" : store.personDisplayName(entry["author"].string),
                      systemImage: ReadingAnnotation.isHighlight(entry) ? "underline" : "pencil.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(entry["author"].string == "Rowan" ? Color.teal : Color.orange)
                Spacer()
                if entry["author"].string == "Vera" {
                    Button {
                        editingID = entry.id
                        editDraft = entry["text"].string
                    } label: { Image(systemName: "pencil").font(.subheadline) }
                        .buttonStyle(.plain).accessibilityLabel("编辑批注")
                }
            }
            if target.range == nil && !entry["quote"].string.isEmpty {
                Text(entry["quote"].string).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if editingID == entry.id {
                TextEditor(text: $editDraft).frame(minHeight: 84)
                    .scrollContentBackground(.hidden)
                HStack {
                    Button("取消") { editingID = nil }.buttonStyle(.bordered)
                    Spacer()
                    Button {
                        editSaving = true
                        let text = editDraft
                        Task {
                            if await edit(entry.id, text) {
                                displayedNotes = visibleNotes.map { $0.id == entry.id ? ReadingAnnotation.edited($0, text: text) : $0 }
                                editingID = nil
                            }
                            editSaving = false
                        }
                    } label: {
                        if editSaving { ProgressView().controlSize(.small) }
                        else { Text("保存修改") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editSaving || (editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry["rangeStart"] == .null))
                }
            } else if ReadingAnnotation.isHighlight(entry) {
                Text("仅划线").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(entry["text"].string).font(.subheadline).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ReadingTextPage: UIViewRepresentable {
    let page: ReadingPage
    let source: String
    let notes: [JSONValue]
    var fontSize: CGFloat = 18
    let openNote: (NSRange, String) -> Void
    let highlight: (NSRange, String) -> Void

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
        view.accessibilityHint = "左右滑动翻页；长按选择文字后可划线或添加批注，点划线查看记录。"
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.page = page
        context.coordinator.openNote = openNote
        context.coordinator.highlight = highlight
        context.coordinator.source = source
        let styled = NSMutableAttributedString(string: page.text, attributes: ReadingLayout.attributes(fontSize: fontSize))
        for entry in notes {
            guard let span = Self.range(for: entry, in: source) else { continue }
            let intersection = NSIntersectionRange(span, page.range)
            guard intersection.length > 0 else { continue }
            let local = NSRange(location: intersection.location - page.range.location, length: intersection.length)
            let color: UIColor = entry["author"].string == "Rowan" ? .systemTeal : .systemOrange
            var decoration: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: color,
                .link: URL(string: "vesper-reading-note://note/\(span.location)")!
            ]
            if !ReadingAnnotation.isHighlight(entry) { decoration[.backgroundColor] = color.withAlphaComponent(0.12) }
            styled.addAttributes(decoration, range: local)
        }
        if !view.attributedText.isEqual(to: styled) { view.attributedText = styled }
    }
    func makeCoordinator() -> Coordinator { Coordinator(page: page, source: source, openNote: openNote, highlight: highlight) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var page: ReadingPage
        var source: String
        var openNote: (NSRange, String) -> Void
        var highlight: (NSRange, String) -> Void
        init(page: ReadingPage, source: String, openNote: @escaping (NSRange, String) -> Void,
             highlight: @escaping (NSRange, String) -> Void) {
            self.page = page; self.source = source; self.openNote = openNote; self.highlight = highlight
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0, NSMaxRange(range) <= (page.text as NSString).length else { return nil }
            let noteAction = UIAction(title: "写批注", image: UIImage(systemName: "pencil.line")) { [weak self] _ in
                guard let self else { return }
                let whole = NSRange(location: self.page.range.location + range.location, length: range.length)
                self.openNote(whole, (self.source as NSString).substring(with: whole))
            }
            let highlightAction = UIAction(title: "只划线", image: UIImage(systemName: "underline")) { [weak self] _ in
                guard let self else { return }
                let whole = NSRange(location: self.page.range.location + range.location, length: range.length)
                self.highlight(whole, (self.source as NSString).substring(with: whole))
            }
            return UIMenu(children: [highlightAction, noteAction] + suggestedActions)
        }
        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem,
                      defaultAction: UIAction) -> UIAction? {
            guard case .link(let url) = textItem.content, url.scheme == "vesper-reading-note",
                  let start = Int(url.lastPathComponent) else { return nil }
            let characterRange = textItem.range
            let sourceText = source as NSString
            let whole = NSRange(location: page.range.location + characterRange.location, length: characterRange.length)
            guard start >= 0, start <= NSMaxRange(whole), NSMaxRange(whole) <= sourceText.length else { return nil }
            // Include every annotation attached to the tapped passage.
            let matching = NSRange(location: start, length: max(1, NSMaxRange(whole) - start))
            guard NSMaxRange(matching) <= sourceText.length else { return nil }
            let excerpt = sourceText.substring(with: matching)
            return UIAction(title: "批注") { [weak self] _ in self?.openNote(matching, excerpt) }
        }
    }
}
