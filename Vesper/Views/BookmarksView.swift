import SwiftUI
import UserNotifications
import CryptoKit

struct BookmarksView: View {
    @State private var section = 0
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(section == 0 ? "订阅" : section == 1 ? "收藏" : "旧书签")
                    .font(.system(size: 16, design: .serif).weight(.medium))
                Spacer()
                Menu {
                    Button { section = 0 } label: { Label("订阅", systemImage: "quote.bubble") }
                    Button { section = 1 } label: { Label("收藏", systemImage: "bookmark") }
                    Button { section = 2 } label: { Label("旧书签", systemImage: "clock.arrow.circlepath") }
                } label: {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 18))
                        .frame(width: 38, height: 38)
                }.accessibilityLabel("切换订阅、收藏或旧书签")
            }.foregroundStyle(VesperTheme.ink).padding(.horizontal, 24)
            if section == 2 { LegacyBookmarksView() }
            else { DailyQuotesView(keptOnly: section == 1) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
    }
}

private struct DailyQuotesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var phase
    let keptOnly: Bool
    @State private var cards: [JSONValue] = []
    @State private var selected: String?
    @State private var loading = false
    @State private var status = ""
    @State private var notify = true
    @State private var dailyCount = 3
    @State private var categories: [String] = []
    @State private var showingComments: JSONValue?
    @State private var deletingCard: JSONValue?
    @State private var showingPreferences = false
    @State private var lastLoadAt: Date?
    private var visible: [JSONValue] { keptOnly ? cards.filter { $0["kept"].bool } : cards }
    var body: some View {
        VStack(spacing: 8) {
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
            if visible.isEmpty {
                Spacer()
                EmptyCard(title: keptOnly ? "还没有收藏" : "今天的句子还在路上", message: keptOnly ? "喜欢的句子，点一下书签就会留在这里。" : "下拉刷新再看看。")
                Spacer()
            } else {
                GeometryReader { bounds in
                    let width = min(440, bounds.size.width * 0.76)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(visible) { card in
                                DailyQuoteCard(card: card,
                                    onKeep: { Task { await keep(card) } },
                                    onComment: { showingComments = card },
                                    onDelete: { deletingCard = card })
                                    .frame(width: width, height: max(400, bounds.size.height - 20))
                                    .id(card.id)
                            }
                        }.scrollTargetLayout().padding(.vertical, 8)
                    }.contentMargins(.horizontal, max(0, (bounds.size.width - width) / 2))
                        .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                        .scrollPosition(id: $selected)
                }
            }
            HStack(spacing: 16) {
                Text(keptOnly ? "只收藏你喜欢的句子" : "左右翻阅")
                    .font(.caption).foregroundStyle(VesperTheme.muted)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading).accessibilityLabel("刷新 Hitokoto")
                Button { showingPreferences = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Hitokoto 偏好与通知")
            }.font(.system(size: 16)).foregroundStyle(VesperTheme.ink).padding(.horizontal, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 12)
        .task(id: store.baseURL + "|" + store.token) {
            if let cached = DailyQuoteViewCache.load(baseURL: store.baseURL, token: store.token) {
                apply(cached)
            }
            await load()
        }
        .onChange(of: phase) { _, next in
            if next == .active, lastLoadAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                Task { await load() }
            }
        }
        .sheet(item: $showingComments, onDismiss: { Task { await load() } }) { card in
            DailyQuoteComments(card: card, api: store.api)
        }
        .sheet(isPresented: $showingPreferences) {
            DailyQuotePreferences(notify: $notify, dailyCount: $dailyCount, categories: $categories, save: savePreferences)
        }
        .alert("删除这张 Hitokoto？", isPresented: Binding(get: { deletingCard != nil }, set: { if !$0 { deletingCard = nil } })) {
            Button("取消", role: .cancel) { deletingCard = nil }
            Button("删除", role: .destructive) {
                if let card = deletingCard { Task { await delete(card) } }
                deletingCard = nil
            }
        } message: { Text("卡片和它的评论会一起删除。") }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let response = try await store.api.request("/api/daily-quotes")
            apply(response)
            DailyQuoteViewCache.save(response, baseURL: store.baseURL, token: store.token)
            lastLoadAt = Date()
            status = ""
        } catch { status = error.localizedDescription }
    }
    private func apply(_ response: JSONValue) {
        cards = response["cards"].array
        notify = response["preferences"]["notify"].bool
        dailyCount = max(1, Int(response["preferences"]["dailyCount"].number))
        categories = response["preferences"]["categories"].array.map(\.string)
    }
    private func keep(_ card: JSONValue) async {
        do {
            let value = !card["kept"].bool
            _ = try await store.api.request("/api/daily-quotes", method: "POST", body: .object([
                "action": .string("keep"), "cardId": .string(card.id), "kept": .bool(value)]))
            await load()
        } catch { status = error.localizedDescription }
    }
    private func delete(_ card: JSONValue) async {
        do {
            let result = try await store.api.request("/api/daily-quotes", method: "POST", body: .object(["action": .string("delete"), "cardId": .string(card.id)]))
            guard result["deleted"].bool else { throw ServiceError(message: "删除未确认。") }
            cards.removeAll { $0.id == card.id }
            if var cached = DailyQuoteViewCache.load(baseURL: store.baseURL, token: store.token) {
                cached["cards"] = .array(cached["cards"].array.filter { $0.id != card.id })
                DailyQuoteViewCache.save(cached, baseURL: store.baseURL, token: store.token)
            }
            await load()
        } catch { status = error.localizedDescription }
    }
    private func savePreferences(_ chosen: [String], _ enabled: Bool, _ count: Int) async throws {
        let response = try await store.api.request("/api/daily-quotes", method: "POST", body: .object([
            "action": .string("preferences"), "categories": .array(chosen.map { .string($0) }),
            "notify": .bool(enabled), "dailyCount": .number(Double(count))]))
        guard response["preferences"]["notify"].bool == enabled else { throw ServiceError(message: "偏好没有保存成功。") }
        await load()
    }
}

private enum DailyQuoteViewCache {
    private static func file(baseURL: String, token: String) -> URL? {
        guard !token.isEmpty,
              let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identity = SHA256.hash(data: Data((baseURL + "\n" + token).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("daily-quotes-\(identity).json")
    }
    static func load(baseURL: String, token: String) -> JSONValue? {
        guard let url = file(baseURL: baseURL, token: token),
              let data = try? Data(contentsOf: url),
              let response = try? JSONDecoder().decode(JSONValue.self, from: data),
              response["cards"] != .null else { return nil }
        return response
    }
    static func save(_ response: JSONValue, baseURL: String, token: String) {
        guard let url = file(baseURL: baseURL, token: token) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(response).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch { /* Cache failure must not delay the visible cards. */ }
    }
}

private struct DailyQuoteCard: View {
    let card: JSONValue
    let onKeep: () -> Void
    let onComment: () -> Void
    let onDelete: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { space in
                if let url = URL(string: card["imageUrl"].string) {
                    AsyncImage(url: url) { state in
                        if let image = state.image { image.resizable().scaledToFill() }
                        else { Color.secondary.opacity(0.12).overlay {
                            if state.error != nil { Text("图片暂时无法载入").font(.caption).foregroundStyle(.secondary) }
                            else { ProgressView() }
                        } }
                    }.frame(width: space.size.width, height: space.size.height).clipped()
                } else { Color.secondary.opacity(0.12).frame(width: space.size.width, height: space.size.height) }
            }.frame(height: 210)
            VStack(alignment: .leading, spacing: 12) {
                Text(card["text"].string)
                    .font(.system(size: 21, design: .serif))
                    .lineSpacing(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                Spacer(minLength: 8)
                if let source = URL(string: card["sourceURL"].string), source.scheme == "https" {
                    Link("— " + card["source"].string, destination: source)
                        .font(.system(size: 13, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text("— " + card["source"].string).font(.system(size: 13, design: .serif))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack {
                    Text("#" + card["category"].string)
                    Spacer()
                    Text(card["day"].string.replacingOccurrences(of: "-", with: " / "))
                }.font(.system(size: 11, design: .serif)).foregroundStyle(.secondary)
                if let imagePage = URL(string: card["imagePageURL"].string), imagePage.scheme == "https" {
                    Link("图片来源 · " + card["licence"].string, destination: imagePage)
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !card["imageSource"].string.isEmpty {
                    Text("图片来源 · " + card["imageSource"].string)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            HStack(spacing: 0) {
                Button(action: onKeep) {
                    Label(card["kept"].bool ? "已收藏" : "收藏", systemImage: card["kept"].bool ? "bookmark.fill" : "bookmark")
                }
                Spacer()
                Button(action: onComment) {
                    Label("\(card["comments"].array.count)", systemImage: "bubble.left")
                }
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .accessibilityLabel("删除 Hitokoto")
                Spacer()
                ShareLink(item: card["text"].string + "\n— " + card["source"].string) {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel("分享 Hitokoto")
            }.font(.system(size: 12)).buttonStyle(.plain)
                .foregroundStyle(Color.black.opacity(0.55))
                .padding(.horizontal, 20).frame(height: 44)
        }
        .foregroundStyle(Color.black.opacity(0.82))
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 3))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
    }
}

private struct DailyQuoteComments: View {
    @Environment(\.dismiss) private var dismiss
    let card: JSONValue
    let api: APIClient
    @State private var draft = ""
    @State private var comments: [JSONValue] = []
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(card["text"].string).font(.system(.title3, design: .serif)).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(comments) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note["author"].string == "Vera" ? "你" : "Ash").font(.caption.bold())
                                Text(note["body"].string).font(.body).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12).vesperMaterial(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                if comments.isEmpty { Text("这里的评论只有你和 Ash 能看见。")
                    .font(.caption).foregroundStyle(.secondary) }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    TextField("说说这句话让你想起了什么…", text: $draft, axis: .vertical).lineLimit(1...4)
                    Button("发送") { Task { await send() } }.disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }.padding(20)
            .navigationTitle("评论").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { await refresh() }
        }
    }
    private func refresh() async {
        do {
            let result = try await api.request("/api/daily-quotes")
            comments = result["cards"].array.first { $0.id == card.id }?["comments"].array ?? []
        } catch { self.error = error.localizedDescription }
    }
    private func send() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await api.request("/api/daily-quotes", method: "POST", body: .object([
                "action": .string("comment"), "id": .string(UUID().uuidString), "cardId": .string(card.id), "body": .string(body)]))
            draft = ""; error = ""; await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

private struct DailyQuotePreferences: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var notify: Bool
    @Binding var dailyCount: Int
    @Binding var categories: [String]
    let save: ([String], Bool, Int) async throws -> Void
    @State private var chosen: Set<String> = []
    @State private var notifications = true
    @State private var count = 3
    @State private var busy = false
    @State private var error = ""
    private let options = ["哲学", "轻文学", "诗歌", "散文", "小说"]
    var body: some View {
        NavigationStack {
            Form {
                Section("内容类型") {
                    Text("不选时会混合推荐；也可以直接告诉 Ash 想看哪类作品。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(options, id: \.self) { option in
                        Button { if !chosen.insert(option).inserted { chosen.remove(option) } } label: {
                            HStack { Text(option); Spacer(); if chosen.contains(option) { Image(systemName: "checkmark") } }
                        }
                    }
                }
                Section("通知") {
                    Stepper("每天 \(count) 句", value: $count, in: 1...5)
                    Toggle("推送每日句子", isOn: $notifications)
                    Text("Ash 会在一天的不同时段分享，并为每句上网找真实图片。关闭通知后，卡片仍会出现在这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Hitokoto 设置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(busy ? "保存中…" : "保存") { Task { await commit() } }.disabled(busy) }
            }
            .background(VesperTheme.palette.surface)
            .onAppear { chosen = Set(categories); notifications = notify; count = dailyCount }
        }
    }
    private func commit() async {
        busy = true; defer { busy = false }
        do { try await save(options.filter { chosen.contains($0) }, notifications, count); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

enum DailyQuoteNotifications {
    static func refresh(api: APIClient) async {
        guard !api.token.isEmpty else { return }
        // Cards exist only after Ash has found a real image. Remove reminders from
        // the old pre-generated schedule so they cannot announce unpublished cards.
        let center = UNUserNotificationCenter.current()
        let current = await center.pendingNotificationRequests()
        let old = current.map(\.identifier).filter { $0.hasPrefix("vesper-daily-quote-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
    }
}

private struct LegacyBookmarksView: View {
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
                else { EmptyCard(title: "留下一句想珍藏的话", message: "你和 \(store.agentDisplayName) 的文字，或共读时遇到的一段话。") }
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
    @EnvironmentObject private var store: AppStore
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
                Text(store.personDisplayName(card["author"].string) + " · " + ChatPresentation.time(card["createdAt"].string)).font(.caption)
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
