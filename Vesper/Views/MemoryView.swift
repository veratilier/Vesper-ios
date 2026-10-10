import SwiftUI

/// Shared Memory remains the source of truth; this view never copies it to the legacy store.
@MainActor
final class SharedMemoryLibrary: ObservableObject {
    var api: APIClient?
    func request(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        guard let api else { throw LibraryError("请先在设置中连接 Vesper。") }
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await api.request("/api/shared-memory?" + (components.percentEncodedQuery ?? ""), method: body == nil ? "GET" : "POST", body: body)
    }
    struct LibraryError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private let libraryKinds = ["episode", "preference", "agreement", "reflection"]
private let memoryCategories = ["episode", "preference_agreement", "reflection"]
private func libraryKind(_ value: String) -> String {
    ["episode": "我们的经历", "preference": "偏好", "agreement": "约定", "preference_agreement": "偏好与约定", "reflection": "感受", "dream": "梦与想象"][value] ?? value
}
private func memoryTitle(_ row: JSONValue) -> String {
    let title = row["details"]["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    let first = row["body"].string.split(whereSeparator: \.isNewline).first.map(String.init) ?? "记忆"
    return String(first.prefix(24)) + (first.count > 24 ? "…" : "")
}
private func memorySummary(_ row: JSONValue) -> String {
    let summary = row["details"]["summary"].string
    return summary.isEmpty ? row["body"].string : summary
}
private func memoryDate(_ value: String) -> String {
    guard !value.isEmpty else { return "日期未记录" }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "日期未记录" }
    return date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
}
private struct MemorySurface: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Dreams retain their original records; only their presentation is separated.
enum DreamDisplay {
    struct Month: Identifiable {
        let id: String
        let title: String
        var records: [JSONValue]
    }
    static func date(_ row: JSONValue) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for key in ["occurred_at", "recorded_at"] {
            let value = row[key].string
            if let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        }
        return nil
    }
    static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
    static func text(_ row: JSONValue) -> String {
        cleanText(row["body"].string)
    }
    static func cleanText(_ value: String) -> String {
        var original = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["【梦】", "【模拟梦境】"] where original.hasPrefix(prefix) {
            original = String(original.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let newline = original.firstIndex(where: \.isNewline),
           ["梦", "梦与想象", "模拟梦境"].contains(String(original[..<newline]).trimmingCharacters(in: .whitespaces)) {
            return String(original[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return original
    }
    static func title(_ row: JSONValue) -> String {
        let title = row["details"]["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && !["梦", "梦与想象", "模拟梦境"].contains(title) { return title }
        let first = text(row).split(whereSeparator: { $0.isNewline || $0 == "。" || $0 == "！" || $0 == "？" }).first.map(String.init) ?? "一场梦"
        return String(first.prefix(24)) + (first.count > 24 ? "…" : "")
    }
    static func months(_ rows: [JSONValue]) -> [Month] {
        let dreams = rows.filter { $0["kind"].string == "dream" }.sorted {
            (date($0) ?? .distantPast) > (date($1) ?? .distantPast)
        }
        var result: [Month] = []
        for row in dreams {
            let date = date(row)
            let key = date.map { format($0, pattern: "yyyy-MM") } ?? "undated"
            if result.last?.id == key { result[result.count - 1].records.append(row) }
            else { result.append(Month(id: key, title: date.map { format($0, pattern: "yyyy年M月") } ?? "日期未记录", records: [row])) }
        }
        return result
    }
}

struct DreamsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var library = SharedMemoryLibrary()
    @State private var rows: [JSONValue] = []
    @State private var query = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var busy = false
    @State private var status = ""
    @State private var generation = 0
    @State private var selected: JSONValue?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "moon.stars").font(.system(size: 25, weight: .light))
                        .frame(width: 58, height: 58).vesperGlass(in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dreams").font(VesperTheme.title(34))
                        Text("夜里留下的片段。").font(.caption).foregroundStyle(VesperTheme.muted)
                    }
                }.padding(.top, 4)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
                    TextField("找一个梦里的片段…", text: $query).submitLabel(.search)
                        .onSubmit { Task { await load(reset: true) } }
                    if !query.isEmpty {
                        Button { query = ""; Task { await load(reset: true) } } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("清空梦的搜索")
                    }
                    Button { Task { await load(reset: true) } } label: { Image(systemName: "arrow.right").frame(width: 32, height: 32) }
                        .accessibilityLabel("搜索梦")
                }.font(.subheadline).padding(.horizontal, 14).padding(.vertical, 7)
                    .vesperGlass(in: RoundedRectangle(cornerRadius: 16)).accessibilityIdentifier("dream-search")
                if !status.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status).font(.caption).textSelection(.enabled)
                        Button("重新加载") { Task { await load(reset: true) } }.font(.caption)
                    }.foregroundStyle(VesperTheme.muted)
                }
                if rows.isEmpty && !busy && status.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "moon").font(.system(size: 32, weight: .ultraLight))
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "等下一场梦，慢慢落在这里。" : "没有找到这个片段。")
                            .font(.subheadline)
                    }.foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity).padding(.vertical, 60)
                }
                ForEach(DreamDisplay.months(rows)) { month in
                    Text(month.title).font(.system(.subheadline, design: .serif)).foregroundStyle(VesperTheme.muted)
                        .padding(.top, 8)
                    ForEach(month.records) { row in
                        Button { selected = row } label: { DreamPreview(row: row) }.buttonStyle(.plain)
                    }
                }
                if busy { ProgressView().frame(maxWidth: .infinity).padding() }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && offset < total {
                    Button { Task { await load(reset: false) } } label: {
                        Label("更早的梦", systemImage: "chevron.down").font(.subheadline)
                            .frame(maxWidth: .infinity).padding(.vertical, 14).vesperGlass(in: Capsule(), interactive: true)
                    }.buttonStyle(.plain).disabled(busy)
                }
                Text("梦境与想象，非真实经历。").font(.caption2).foregroundStyle(VesperTheme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }.padding(20).padding(.bottom, 80)
        }.scrollDismissesKeyboard(.interactively).foregroundStyle(VesperTheme.ink)
            .accessibilityIdentifier("dream-archive")
            .task(id: store.baseURL + "\n" + store.token) {
                library.api = store.api; rows = []; offset = 0; total = 0
                await load(reset: true)
            }
            .refreshable { await load(reset: true) }
            .sheet(item: $selected, onDismiss: { Task { await load(reset: true) } }) { row in
                NavigationStack {
                    LibraryRecordView(library: library, id: row.id, dream: true)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
                }.presentationDragIndicator(.visible)
            }
    }
    private func load(reset: Bool) async {
        if !reset && busy { return }
        generation += 1; let ticket = generation
        let start = reset ? 0 : offset
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; status = ""
        defer { if ticket == generation { busy = false } }
        do {
            let response: JSONValue
            if text.isEmpty {
                var params = URLComponents()
                params.queryItems = [URLQueryItem(name: "kind", value: "dream"), URLQueryItem(name: "offset", value: String(start)),
                                     URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "include_superseded", value: "false")]
                response = try await library.request("/api/memories?" + (params.percentEncodedQuery ?? ""))
            } else {
                response = try await library.request("/api/search", body: .object(["query": .string(text), "kind": .string("dream"),
                    "limit": .number(20), "include_nonfacts": .bool(true), "include_superseded": .bool(false)]))
            }
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let page = response[text.isEmpty ? "items" : "hits"].array
            let dreams = page.filter { $0["kind"].string == "dream" }
            var seen = Set<String>()
            rows = ((reset ? [] : rows) + dreams).filter { seen.insert($0.id).inserted }
            offset = start + page.count
            total = text.isEmpty ? Int(response["total"].number) : rows.count
            status = response["warnings"].array.map(\.string).joined(separator: " · ")
        } catch {
            if ticket == generation && !Task.isCancelled {
                if reset { rows = []; offset = 0; total = 0 }
                status = error.localizedDescription
            }
        }
    }
}

private struct DreamPreview: View {
    let row: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "moon").font(.caption2)
                Text(DreamDisplay.date(row).map { DreamDisplay.format($0, pattern: "M月d日") } ?? "日期未记录")
                Spacer()
                Image(systemName: "chevron.right").font(.caption2)
            }.font(.caption).foregroundStyle(VesperTheme.muted)
            Text(DreamDisplay.title(row)).font(.system(.title3, design: .serif)).lineLimit(2).foregroundStyle(VesperTheme.ink)
            Text(row["details"]["summary"].string.isEmpty ? DreamDisplay.text(row) : DreamDisplay.cleanText(row["details"]["summary"].string))
                .font(.subheadline).lineSpacing(5).lineLimit(4).foregroundStyle(VesperTheme.muted)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .vesperGlass(in: RoundedRectangle(cornerRadius: 24)).accessibilityIdentifier("dream-" + row.id)
    }
}

struct MemoryView: View {
    @StateObject private var library = SharedMemoryLibrary()
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var kind = "episode"
    @State private var oldVersions = false
    @State private var rows: [JSONValue] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var generation = 0
    @State private var busy = false
    @State private var status = ""
    @State private var adding = false
    @State private var filtering = false
    @State private var reviewing = false
    @State private var recentExpanded = false
    @State private var deliveries: [JSONValue] = []
    @State private var recallStatus = ""
    @State private var selected: JSONValue?

    var body: some View {
        VStack(spacing: 10) {
            header
            search
            categories
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    Button("相关记忆与待核对候选") { reviewing = true }.font(.caption).padding(.vertical, 6)
                    recent
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(VesperTheme.muted).padding(.vertical, 6) }
                    if busy { ProgressView().frame(maxWidth: .infinity).padding() }
                    if rows.isEmpty && !busy && status.isEmpty {
                        Text(query.isEmpty ? "这里还没有记忆，等值得留下的内容。" : "没有找到相关记忆，换几个关键词试试。")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted).padding(.vertical, 30)
                    }
                    ForEach(rows) { row in
                        Button { selected = row } label: { LibraryPreviewCard(row: row) }.buttonStyle(.plain)
                    }
                    pagination
                }.padding(.horizontal, 18).padding(.top, 3).padding(.bottom, 90)
            }.scrollDismissesKeyboard(.interactively)
                .refreshable { await load(); await loadRecent() }
        }
        .foregroundStyle(VesperTheme.ink)
        .task { library.api = store.api; await load() }
        .onChange(of: kind) { _, _ in refresh() }
        .onChange(of: recentExpanded) { _, expanded in if expanded { Task { await loadRecent() } } }
        .sheet(isPresented: $reviewing) { MemoryRecallView(conversationID: nil, includeDreams: false) }
        .sheet(isPresented: $adding) { LibraryEditor(library: library, record: nil) { refresh() } }
        .sheet(isPresented: $filtering) { filters }
        .sheet(item: $selected, onDismiss: { refresh() }) { row in
            NavigationStack { LibraryRecordView(library: library, id: row.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } } }
                .presentationDragIndicator(.visible)
        }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory").font(VesperTheme.title(29))
                Text("把一起走过的，留在这里。").font(.caption).foregroundStyle(VesperTheme.muted)
            }
            Spacer()
            Button { adding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44).vesperGlass(in: Circle(), interactive: true) }.accessibilityLabel("新增记忆")
        }.padding(.horizontal, 20).padding(.top, 8)
    }
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
            TextField("找一句话，一件旧事…", text: $query).font(.subheadline).submitLabel(.search).onSubmit { refresh() }
            if !query.isEmpty {
                Button { query = ""; refresh() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索")
            }
            Button { filtering = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }.accessibilityLabel("筛选记忆")
        }.padding(.horizontal, 12).padding(.vertical, 5).vesperGlass(in: RoundedRectangle(cornerRadius: 15)).padding(.horizontal, 18)
    }
    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(memoryCategories, id: \.self) { value in
                    Button { kind = value } label: {
                        Text(libraryKind(value)).font(.subheadline).padding(.horizontal, 11).padding(.vertical, 9)
                            .foregroundStyle(kind == value ? (VesperTheme.palette == .black ? Color.black : Color.white) : VesperTheme.muted)
                            .background(kind == value ? VesperTheme.muted : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityAddTraits(kind == value ? .isSelected : [])
                }
            }.padding(.horizontal, 18)
        }
    }
    private var recent: some View {
        DisclosureGroup(isExpanded: $recentExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("这里只表示记忆已提供给模型，不代表回复一定采用了它。").font(.caption).foregroundStyle(VesperTheme.muted)
                if !recallStatus.isEmpty { Text(recallStatus).font(.caption) }
                ForEach(Array(deliveries.prefix(5).enumerated()), id: \.offset) { _, delivery in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(memoryDate(delivery["deliveredAt"].string)).font(.caption2).foregroundStyle(VesperTheme.muted)
                        ForEach(delivery["memories"].array) { memory in
                            NavigationLink { LibraryRecordView(library: library, id: memory.id) } label: {
                                Text(memory["body"].string).font(.caption).fontWeight(.regular).lineLimit(3).multilineTextAlignment(.leading)
                            }
                        }
                        Button("查看关联聊天") { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: ["conversationId": delivery["conversationId"].string, "messageId": delivery["messageId"].string]) }.font(.caption)
                    }
                }
            }.padding(.top, 10)
        } label: { Label("最近浮现", systemImage: "sparkles").font(.caption) }
            .tint(VesperTheme.muted).modifier(MemorySurface()).padding(.bottom, 6)
    }
    @ViewBuilder private var pagination: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && total > 40 {
            HStack {
                Button("上一页") { offset = max(0, offset - 40); Task { await load() } }.disabled(offset == 0 || busy)
                Spacer(); Text("\(offset + 1)–\(min(offset + rows.count, total)) / \(total)").font(.caption); Spacer()
                Button("下一页") { offset += 40; Task { await load() } }.disabled(offset + 40 >= total || busy)
            }.font(.caption).padding(.vertical, 12)
        }
    }
    private var filters: some View {
        NavigationStack {
            Form {
                Section("记录范围") { Toggle("包含已替代、已撤回及待核对记录", isOn: $oldVersions) }
                Section { NavigationLink("旧 Vesper 记忆") { LegacyMemoryView() } }
            }.navigationTitle("筛选记忆").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { filtering = false; refresh() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func refresh() { offset = 0; Task { await load() } }
    private func loadRecent() async {
        do {
            let result = try await store.api.request("/api/memory/context")
            deliveries = result["items"].array.compactMap { item in
                var delivery = item
                delivery["memories"] = .array(item["memories"].array.filter { $0["kind"].string != "dream" })
                return delivery["status"].string == "delivered" && !delivery["memories"].array.isEmpty ? delivery : nil
            }
            recallStatus = result["unavailable"].bool ? "最近浮现暂时不可用。" : deliveries.isEmpty ? "还没有已提供给模型的记忆记录。" : ""
        } catch { recallStatus = "最近浮现暂时不可用：" + error.localizedDescription }
    }
    private func load() async {
        generation += 1; let ticket = generation
        busy = true; status = ""
        defer { if ticket == generation { busy = false } }
        do {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let response: JSONValue
            if text.isEmpty {
                var params = URLComponents()
                params.queryItems = [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "include_superseded", value: String(oldVersions)), URLQueryItem(name: "kind", value: kind)]
                response = try await library.request("/api/memories?" + (params.percentEncodedQuery ?? ""))
            } else {
                response = try await library.request("/api/search", body: .object(["query": .string(text), "limit": .number(20), "include_superseded": .bool(oldVersions), "include_nonfacts": .bool(kind == "reflection" || kind == "dream"), "kind": .string(kind)]))
            }
            guard ticket == generation else { return }
            rows = response[text.isEmpty ? "items" : "hits"].array.filter { $0["kind"].string != "dream" }
            total = text.isEmpty ? Int(response["total"].number) : rows.count
            status = response["warnings"].array.map(\.string).joined(separator: " · ")
        } catch { if ticket == generation { rows = []; status = error.localizedDescription } }
    }
}

private struct LibraryPreviewCard: View {
    let row: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(memoryDate(row["occurred_at"].string))
                Spacer()
                if row["kind"].string == "dream" { Text("虚构") }
                if row["kind"].string == "reflection" { Text("主观感受") }
                if row["active"].number == 0 { Text("历史记录") }
                Image(systemName: "arrow.up.right").font(.caption2)
            }.font(.caption2).foregroundStyle(VesperTheme.muted)
            Text(memoryTitle(row)).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(VesperTheme.ink)
            Text(memorySummary(row)).font(.caption).fontWeight(.regular).lineSpacing(2).lineLimit(3).foregroundStyle(VesperTheme.muted)
        }.modifier(MemorySurface())
    }
}

private struct LibraryRecordView: View {
    @ObservedObject var library: SharedMemoryLibrary
    let id: String
    var dream = false
    @State private var record: JSONValue = .null
    @State private var status = ""
    @State private var editing = false
    @State private var withdrawing = false
    @State private var reason = ""
    @State private var busy = false
    var body: some View {
        ZStack {
            Background()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if record != .null {
                        Text(libraryKind(record["kind"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                        Text(dream ? DreamDisplay.title(record) : memoryTitle(record)).font(.system(.title3, design: dream ? .serif : .default).weight(.medium))
                        Text(dream ? (DreamDisplay.date(record).map { DreamDisplay.format($0, pattern: "yyyy年M月d日") } ?? "日期未记录") : memoryDate(record["occurred_at"].string)).font(.caption).foregroundStyle(VesperTheme.muted)
                        if ["dream", "reflection"].contains(record["kind"].string) {
                            Text(record["kind"].string == "dream" ? "梦与想象 · 虚构，非真实经历" : "主观感受 · 不等同于事实").font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        Text(dream ? DreamDisplay.text(record) : record["body"].string).font(.subheadline).fontWeight(.regular).lineSpacing(dream ? 7 : 4).textSelection(.enabled).modifier(MemorySurface())
                        if record["withdrawal"] != .null { Text("已撤回：" + record["withdrawal"]["reason"].string).font(.caption) }
                        if record["review"] != .null { Text("待核对：" + record["review"]["reason"].string).font(.caption) }
                        sources
                        versions
                        if record["active"].number == 1 {
                            HStack {
                                Button { editing = true } label: { Label("纠正", systemImage: "pencil") }
                                Button(role: .destructive) { reason = ""; withdrawing = true } label: { Label("撤回", systemImage: "archivebox") }
                            }.buttonStyle(.bordered).disabled(busy)
                        }
                    } else if status.isEmpty { ProgressView() }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(VesperTheme.muted) }
                }.padding(20).padding(.bottom, 80)
            }
        }.foregroundStyle(VesperTheme.ink).navigationTitle(dream ? "梦" : "记忆详情").navigationBarTitleDisplayMode(.inline).task { await load() }
        .sheet(isPresented: $editing) { LibraryEditor(library: library, record: record) { Task { await load() } } }
        .alert("撤回这条记忆？", isPresented: $withdrawing) {
            TextField("撤回原因", text: $reason)
            Button("取消", role: .cancel) {}
            Button("撤回", role: .destructive) { Task { await withdraw() } }
        } message: { Text("将停止参与新的召回，原文与来源仍保留。") }
    }
    private var sources: some View {
        DisclosureGroup("来源与原始聊天") {
            VStack(alignment: .leading, spacing: 12) {
                Text(record["source"].string).textSelection(.enabled)
                ForEach(Array(record["details"]["evidence"].array.enumerated()), id: \.offset) { _, evidence in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(evidence["quote"].string).font(.subheadline).fontWeight(.regular).textSelection(.enabled)
                        if !evidence["conversation_id"].string.isEmpty {
                            Button("查看原始聊天") { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: ["conversationId": evidence["conversation_id"].string, "messageId": evidence["message_id"].string]) }
                        }
                    }
                }
                if let url = URL(string: record["source_url"].string), ["https", "http"].contains(url.scheme ?? "") { Link("打开来源", destination: url) }
                Text("记录时间：" + memoryDate(record["recorded_at"].string))
                Text("来源标识：" + record["source_id"].string).textSelection(.enabled)
                Text("记录 ID：" + id).textSelection(.enabled)
            }.font(.caption).padding(.top, 10)
        }.font(.subheadline).tint(VesperTheme.muted)
    }
    private var versions: some View {
        DisclosureGroup("版本与修订") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(record["versions"].array) { version in
                    NavigationLink { LibraryRecordView(library: library, id: version.id, dream: dream) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("v\(Int(version["version"].number)) · " + (version["active"].number == 1 ? "当前版本" : "历史版本"))
                            Text(version["correction_reason"].string).font(.caption)
                        }
                    }.disabled(version.id == id)
                }
            }.padding(.top, 10)
        }.font(.subheadline).tint(VesperTheme.muted)
    }
    private func load() async {
        do {
            let value = try await library.request("/api/memories/" + id)
            if dream && value["kind"].string != "dream" { throw SharedMemoryLibrary.LibraryError("这条记录不是梦，请返回重新选择。") }
            record = value; status = ""
        }
        catch { status = error.localizedDescription }
    }
    private func withdraw() async {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "请填写撤回原因。"; return }
        busy = true; defer { busy = false }
        do { _ = try await library.request("/api/memories/" + id + "/withdraw", body: .object(["reason": .string(reason)])); await load() }
        catch { status = error.localizedDescription }
    }
}

private struct LibraryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: SharedMemoryLibrary
    let record: JSONValue?
    let saved: () -> Void
    var candidateID: String? = nil
    @State private var title = ""
    @State private var summary = ""
    @State private var bodyText = ""
    @State private var source = ""
    @State private var sourceURL = ""
    @State private var kind = "episode"
    @State private var reason = ""
    @State private var hasDate = false
    @State private var occurredDate = Date()
    @State private var busy = false
    @State private var error = ""
    var body: some View {
        EditorSheet(title: candidateID != nil ? "修改候选" : record == nil ? "新增记忆" : record?["kind"].string == "dream" ? "修订梦" : "纠正记忆", busy: busy, save: { Task { await save() } }) {
            FormField(label: "短标题（可选）", text: $title)
            FormField(label: "摘要（可选）", text: $summary)
            FormField(label: "原文", text: $bodyText, multiline: true)
            FormField(label: "来源说明", text: $source)
            if record?["kind"].string == "dream" { Text("梦与想象").font(.caption).foregroundStyle(VesperTheme.muted) }
            else { Picker("类型", selection: $kind) { ForEach(libraryKinds, id: \.self) { Text(libraryKind($0)).tag($0) } } }
            FormField(label: "来源链接（可留空）", text: $sourceURL)
            Toggle("已知发生时间", isOn: $hasDate)
            if hasDate { DatePicker("发生时间", selection: $occurredDate) }
            if record != nil && candidateID == nil { FormField(label: "纠正原因（保留旧版本）", text: $reason) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }.onAppear {
            if let record {
                title = record["details"]["title"].string; summary = record["details"]["summary"].string
                bodyText = record["body"].string; source = record["source"].string
                sourceURL = record["source_url"].string; kind = record["kind"].string
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: record["occurred_at"].string) ?? ISO8601DateFormatter().date(from: record["occurred_at"].string) { occurredDate = date; hasDate = true }
            }
        }.interactiveDismissDisabled(busy)
    }
    private func save() async {
        guard !busy else { return }
        guard !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (record == nil || candidateID != nil) || !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "请填写原文、来源和必要的纠正原因。"; return }
        guard title.count <= 100, summary.count <= 500 else { error = "标题最多 100 字，摘要最多 500 字。"; return }
        busy = true; defer { busy = false }
        do {
            var payload: [String: JSONValue] = ["body": .string(bodyText), "source": .string(source), "kind": .string(kind), "source_url": sourceURL.isEmpty ? .null : .string(sourceURL), "occurred_at": hasDate ? .string(ISO8601DateFormatter().string(from: occurredDate)) : .null]
            var details = record?["details"].object ?? [:]
            details.removeValue(forKey: "title"); details.removeValue(forKey: "summary")
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { details["title"] = .string(title) }
            if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { details["summary"] = .string(summary) }
            if !details.isEmpty { payload["details"] = .object(details) }
            if record != nil && candidateID == nil { payload["correction_reason"] = .string(reason) }
            if let candidateID, let api = library.api {
                let result = try await api.request("/api/memory/candidates", method: "POST", body: .object(["action": .string("edit"), "id": .string(candidateID), "memory": .object(payload)]))
                guard result["status"].string == "pending" else { throw SharedMemoryLibrary.LibraryError("候选已改变，请重新加载。") }
                saved(); dismiss(); return
            }
            let path = record.map { "/api/memories/" + $0.id + "/correct" } ?? "/api/memories"
            let response = try await library.request(path, body: .object(payload))
            guard !response.id.isEmpty else { throw SharedMemoryLibrary.LibraryError("保存结果缺少记录标识，尚未确认成功。") }
            saved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct LegacyMemoryView: View {
    @EnvironmentObject private var store: AppStore
    @State private var items: [JSONValue] = []
    @State private var evidence: [JSONValue] = []
    @State private var section = "Timeline"
    @State private var filter = "Recent"
    @State private var query = ""
    @State private var status = ""
    @State private var adding = false
    @State private var text = ""
    @State private var tags = ""
    @State private var busy = false
    private var visible: [JSONValue] {
        let selected = items.filter { item in
            switch filter {
            case "Current": return item["type"].string == "core" && item["reviewStatus"].string == "approved" && item["demotedAt"] == .null
            case "Corrected": return item["correctedAt"] != .null
            default: return true
            }
        }
        return selected.sorted { filter == "Recalled" ? $0["surfaceCount"].number > $1["surfaceCount"].number : $0["updatedAt"].string > $1["updatedAt"].string }
    }
    var body: some View {
        Page(title: "Memory", subtitle: "What we remember, and where it began.") {
            Picker("Memory view", selection: $section) {
                ForEach(["Timeline", "Relations", "Vault"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                TextField("Search memories", text: $query).submitLabel(.search).onSubmit { Task { await load() } }
                Button { Task { await load() } } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search memories")
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add memory")
            }.padding(14).vesperMaterial(.regularMaterial, in: Capsule())
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(VesperTheme.muted) }
            if section == "Timeline" {
                Picker("Sort and filter", selection: $filter) { ForEach(["Recent", "Current", "Corrected", "Recalled"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                ForEach(visible) { memory in
                    NavigationLink { MemoryDetailView(memory: memory) } label: { MemoryCard(memory: memory) }.buttonStyle(.plain)
                }
            } else if section == "Relations" {
                MemoryRelations(items: items)
            } else {
                Text("Original sources").font(.headline)
                if evidence.isEmpty { EmptyCard(title: "No original sources yet", message: "Older memories may not have a saved source. New saved messages retain their original text and attachment references here.") }
                ForEach(evidence) { source in
                    NavigationLink { EvidenceView(evidence: source) } label: {
                        GlassCard { VStack(alignment: .leading, spacing: 8) {
                            Text(source["content"].string.isEmpty ? "Attachment" : source["content"].string).lineLimit(3)
                            Text(source["createdAt"].string).font(.caption).foregroundStyle(VesperTheme.muted)
                        } }
                    }.buttonStyle(.plain)
                }
            }
        }.task { await load() }.refreshable { await load() }
        .sheet(isPresented: $adding) {
            EditorSheet(title: "New core memory", busy: busy, save: { Task { await save() } }) {
                FormField(label: "Memory", text: $text, multiline: true)
                FormField(label: "People, topics or places (comma separated)", text: $tags)
            }
        }
    }
    private func load() async {
        do {
            var params = URLComponents(); params.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "includeDemoted", value: "1"), URLQueryItem(name: "includeCandidates", value: "1")]
            let response = try await store.api.request("/api/memory?" + (params.percentEncodedQuery ?? "")); items = response["memories"].array
            status = items.isEmpty ? "No memories found." : ""
            do { let vault = try await store.api.request("/api/memory?view=vault"); evidence = vault["evidence"].array }
            catch { status = "Memories loaded. Original sources are unavailable: " + error.localizedDescription }
        } catch { status = error.localizedDescription }
    }
    private func save() async {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { status = "Add a little more detail."; return }
        busy = true; defer { busy = false }
        do {
            _ = try await store.api.request("/api/memory", method: "POST", body: .object(["action": .string("create_core"), "body": .string(text), "tags": .string(tags)]))
            text = ""; tags = ""; adding = false; await load()
        } catch { store.error = error.localizedDescription }
    }
}
struct MemoryCard: View {
    let memory: JSONValue
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(memory["type"].string.replacingOccurrences(of: "_", with: " ")).font(.caption); Spacer(); if memory["pinned"].bool { Image(systemName: "pin.fill") } }
                Text(memory["body"].string).font(.body).lineLimit(6)
                Text(memory["demotedAt"] != .null ? "Historical · no longer active" : memory["reviewStatus"].string == "candidate" ? "Awaiting confirmation" : "Confirmed").font(.caption).foregroundStyle(VesperTheme.muted)
                Text(ChatPresentation.time(memory["updatedAt"].string)).font(.caption2).foregroundStyle(VesperTheme.muted)
            }
        }
    }
}
struct MemoryDetailView: View {
    @EnvironmentObject private var store: AppStore
    let memory: JSONValue
    @State private var detail: JSONValue = .null
    @State private var editing = false
    @State private var replacement = ""
    @State private var reason = ""
    @State private var busy = false
    @State private var error = ""
    private var current: JSONValue { detail["memory"] == .null ? memory : detail["memory"] }
    var body: some View {
        ZStack { Background(); Page(title: "Memory") {
            MemoryCard(memory: current)
            Text("Source: " + current["source"].string).font(.caption)
            Text("Recorded: " + current["createdAt"].string).font(.caption)
            Text("Recalled \(Int(current["surfaceCount"].number)) times").font(.caption)
            Text(current["confidence"] == .null ? "Confidence: not recorded" : "Confidence: \(Int(current["confidence"].number * 100))%").font(.caption)
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Correct") { replacement = current["body"].string; editing = true }
                Button(current["pinned"].bool ? "Unpin" : "Pin") { Task { await update("pin", extra: ["pinned": .bool(!current["pinned"].bool)]) } }
                Button(current["demotedAt"] == .null ? "Make historical" : "Restore") { Task { await update(current["demotedAt"] == .null ? "demote" : "restore") } }
            }.buttonStyle(.bordered).disabled(busy)
            if current["reviewStatus"].string == "candidate" && current["type"].string == "core" { Button("Confirm this fact") { Task { await update("approve_core") } }.disabled(busy) }
            Text("Original evidence").font(.headline)
            if detail["evidence"].array.isEmpty { Text("No original source was linked to this memory.").font(.caption).foregroundStyle(VesperTheme.muted) }
            ForEach(detail["evidence"].array) { source in NavigationLink { EvidenceView(evidence: source) } label: { Label(String(source["content"].string.prefix(90)), systemImage: "doc.text.magnifyingglass") } }
            Text("Version history").font(.headline)
            ForEach(detail["revisions"].array) { revision in
                GlassCard { VStack(alignment: .leading, spacing: 8) {
                    Text(revision["body"].string).textSelection(.enabled)
                    Text(revision["reason"].string).font(.caption)
                    Text(revision["createdAt"].string + " · " + revision["action"].string).font(.caption2).foregroundStyle(VesperTheme.muted)
                } }
            }
        } }.navigationBarTitleDisplayMode(.inline).task { await load() }
        .sheet(isPresented: $editing) {
            EditorSheet(title: "Correct memory", busy: busy, save: { Task {
                await update(current["type"].string == "core" ? "correct_core" : "correct", extra: ["body": .string(replacement), "reason": .string(reason), "tags": current["tags"], "mood": current["mood"]])
                if error.isEmpty { editing = false }
            } }) { FormField(label: "Current fact", text: $replacement, multiline: true); FormField(label: "Why this changed", text: $reason); if !error.isEmpty { Text(error).foregroundStyle(.red) } }
        }
    }
    private func load() async {
        do { var q = URLComponents(); q.queryItems = [URLQueryItem(name: "id", value: memory.id)]; detail = try await store.api.request("/api/memory?" + (q.percentEncodedQuery ?? "")); error = "" }
        catch { self.error = error.localizedDescription }
    }
    private func update(_ action: String, extra: [String: JSONValue] = [:]) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { var body = extra; body["id"] = .string(memory.id); body["action"] = .string(action); _ = try await store.api.request("/api/memory", method: "PATCH", body: .object(body)); await load() }
        catch { self.error = error.localizedDescription }
    }
}
struct EvidenceView: View {
    let evidence: JSONValue
    var body: some View {
        ZStack { Background(); Page(title: "Original source") {
            Text(evidence["createdAt"].string).font(.caption)
            Text(evidence["content"].string).textSelection(.enabled)
            ForEach(Array(evidence["attachments"].array.enumerated()), id: \.offset) { _, attachment in
                if let url = URL(string: attachment["url"].string), url.scheme == "https" { Link(attachment["name"].string.isEmpty ? "Open attachment" : attachment["name"].string, destination: url) }
            }
            Text("Conversation: " + evidence["conversationId"].string).font(.caption).textSelection(.enabled)
            if evidence["conversationId"].string != "manual-memory" { Button("Open original conversation") { NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: ["conversationId": evidence["conversationId"].string, "messageId": evidence["messageId"].string]) } }
        } }.navigationBarTitleDisplayMode(.inline)
    }
}
private struct MemoryRelations: View {
    let items: [JSONValue]
    @State private var tag = ""
    private var tags: [String] { Array(Set(items.flatMap { $0["tags"].array.map(\.string) })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Connections through saved people, places and topics").font(.caption).foregroundStyle(VesperTheme.muted)
            if !tags.isEmpty { MemoryRelationGraph(items: items) }
            if tags.isEmpty { EmptyCard(title: "No connections yet", message: "Add people, places or topics to a memory to connect its records.") }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 12) {
                ForEach(tags, id: \.self) { value in Button { tag = value } label: { Text(value).padding(12).frame(maxWidth: .infinity).background(tag == value ? VesperTheme.accent.opacity(0.3) : .clear, in: Capsule()).vesperGlass(in: Capsule(), interactive: true) }.buttonStyle(.plain) }
            }
            if !tag.isEmpty {
                ForEach(items.filter { $0["tags"].array.contains(.string(tag)) }) { item in
                    NavigationLink { MemoryDetailView(memory: item) } label: { HStack { Image(systemName: "link"); MemoryCard(memory: item) } }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct MemoryRelationGraph: View {
    let items: [JSONValue]
    @State private var selected: JSONValue?
    private var records: [JSONValue] { Array(items.filter { !$0["tags"].array.isEmpty }.prefix(10)) }
    private var topics: [String] { Array(Set(records.flatMap { $0["tags"].array.map(\.string) })).sorted().prefix(8).map { $0 } }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    for (i, memory) in records.enumerated() {
                        for (j, topic) in topics.enumerated() where memory["tags"].array.contains(.string(topic)) {
                            var edge = Path(); edge.move(to: point(i, count: records.count, outer: true, size: size)); edge.addLine(to: point(j, count: topics.count, outer: false, size: size))
                            context.stroke(edge, with: .color(VesperTheme.accent.opacity(0.35)), lineWidth: 1)
                        }
                    }
                }
                ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                    Text(topic).font(.caption2).lineLimit(2).padding(7).vesperMaterial(.regularMaterial, in: Capsule())
                        .position(point(index, count: topics.count, outer: false, size: geometry.size))
                }
                ForEach(Array(records.enumerated()), id: \.element.id) { index, memory in
                    Button { selected = memory } label: {
                        Image(systemName: "doc.text").frame(width: 38, height: 38).vesperMaterial(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(VesperTheme.accent.opacity(0.5)))
                    }.accessibilityLabel(memory["body"].string).position(point(index, count: records.count, outer: true, size: geometry.size))
                }
            }
        }.frame(height: 320)
        .sheet(item: $selected) { item in NavigationStack { MemoryDetailView(memory: item).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } } } } }
    }
    private func point(_ index: Int, count: Int, outer: Bool, size: CGSize) -> CGPoint {
        let angle: Double = Double(index) / Double(max(1, count)) * 2 * Double.pi - Double.pi / 2
        let radius: CGFloat = min(size.width / 2 - 24, 138) * (outer ? 1 : 0.47)
        return CGPoint(x: size.width/2 + CGFloat(cos(angle))*radius, y: size.height/2 + CGFloat(sin(angle))*radius)
    }
}




/// Actual acknowledged context and source-checked proposals, never claims of model use.
struct MemoryRecallView: View {
    let conversationID: String?
    var includeDreams = true
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = SharedMemoryLibrary()
    @State private var deliveries: [JSONValue] = []
    @State private var candidates: [JSONValue] = []
    @State private var editingCandidate: JSONValue?
    @State private var error = ""
    @State private var busy = false
    @State private var debug = false
    var body: some View {
        NavigationStack {
            List {
                Section { Text("这里记录实际提供给模型的历史资料，不表示回复一定采用。待核对候选不会参与召回。").font(.caption) }
                if !error.isEmpty { Section { Text(error).foregroundStyle(.red); Button("重试") { Task { await load() } } } }
                if busy { ProgressView() }
                Section("待核对经历") {
                    if candidates.isEmpty { Text("暂无待核对候选").foregroundStyle(.secondary) }
                    ForEach(candidates) { item in
                        DisclosureGroup(item["details"]["title"].string.isEmpty ? "查看候选" : item["details"]["title"].string) {
                            Text(item["body"].string).textSelection(.enabled)
                            Text("发生日期：" + (item["occurred_at"].string.isEmpty ? "未知" : item["occurred_at"].string)).font(.caption)
                            if !item["details"]["interpretation"].string.isEmpty { Text("主观解释：" + item["details"]["interpretation"].string).font(.caption) }
                            sources(item["details"]["evidence"].array)
                            Button("先修改候选") { editingCandidate = item }.buttonStyle(.bordered)
                            HStack {
                                Button("核对无误，入库") { Task { await review(item, action: "accept") } }.buttonStyle(.bordered)
                                Button("不保存", role: .destructive) { Task { await review(item, action: "reject") } }.buttonStyle(.bordered)
                            }.disabled(busy)
                        }
                    }
                }
                Section("已提供的相关记忆") {
                    if deliveries.isEmpty { Text("暂无已确认送达的召回记录").foregroundStyle(.secondary) }
                    ForEach(Array(deliveries.enumerated()), id: \.offset) { _, delivery in
                        DisclosureGroup(delivery["deliveredAt"].string) {
                            ForEach(delivery["memories"].array) { memory in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(memory["reason"].string == "standing_preference" ? "持续偏好 / 约定" : "相关经历").font(.caption).foregroundStyle(.secondary)
                                    Text(memory["body"].string)
                                    NavigationLink("查看原文、来源与纠正") { LibraryRecordView(library: library, id: memory.id) }
                                    sources(memory["details"]["evidence"].array)
                                    Button("不相关") { Task { await feedback(delivery, memory: memory) } }.buttonStyle(.bordered).disabled(busy)
                                }.padding(.vertical, 6)
                            }
                            if debug { Text(delivery["diagnostics"].pretty).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }
                    }
                }
                Section { Toggle("调试详情（检索输入、评分与预算）", isOn: $debug).onChange(of: debug) { _, _ in Task { await load() } } }
            }.navigationTitle("相关记忆").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                .sheet(item: $editingCandidate) { item in LibraryEditor(library: library, record: item, saved: { Task { await load() } }, candidateID: item.id) }
                .task { library.api = store.api; await load() }
                .refreshable { await load() }
        }
    }
    @ViewBuilder private func sources(_ refs: [JSONValue]) -> some View {
        ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in
            if !ref["quote"].string.isEmpty { Text("原话：" + ref["quote"].string).font(.caption).textSelection(.enabled) }
            Button("回到来源消息") {
                NotificationCenter.default.post(name: .init("VesperOpenConversation"), object: nil, userInfo: ["conversationId": ref["conversation_id"].string, "messageId": ref["message_id"].string]); dismiss()
            }.font(.caption)
        }
    }
    private func load() async {
        busy = true; defer { busy = false }
        do {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "debug", value: debug ? "1" : "0")]
            if let conversationID { query.queryItems?.append(URLQueryItem(name: "conversationId", value: conversationID)) }
            let result = try await store.api.request("/api/memory/context?" + (query.percentEncodedQuery ?? ""))
            deliveries = result["items"].array.compactMap { item in
                if includeDreams { return item }
                var delivery = item
                delivery["memories"] = .array(item["memories"].array.filter { $0["kind"].string != "dream" })
                return !delivery["memories"].array.isEmpty ? delivery : nil
            }
            let pending = try await store.api.request("/api/memory/candidates")
            candidates = pending["items"].array.filter { includeDreams || $0["kind"].string != "dream" }
            error = result["unavailable"].bool ? "召回记录暂时不可用。" : ""
        } catch { self.error = error.localizedDescription }
    }
    private func review(_ item: JSONValue, action: String) async {
        busy = true
        do { _ = try await store.api.request("/api/memory/candidates", method: "POST", body: .object(["id": item["id"], "action": .string(action)])); await load() }
        catch { self.error = error.localizedDescription; busy = false }
    }
    private func feedback(_ delivery: JSONValue, memory: JSONValue) async {
        busy = true
        do { _ = try await store.api.request("/api/memory/context", method: "POST", body: .object(["action": .string("feedback"), "deliveryId": delivery["deliveryId"], "memoryId": memory["id"], "kind": .string("irrelevant")])); await load() }
        catch { self.error = error.localizedDescription; busy = false }
    }
}
