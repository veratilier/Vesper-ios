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
    @State private var offset = 0
    @State private var total = 0
    @State private var busy = false
    @State private var status = ""
    @State private var generation = 0
    @State private var selected: JSONValue?
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dreams").font(.system(size: 30, weight: .regular, design: .serif))
                    Text("一页一梦，左右翻看。").font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Spacer()
                Button { Task { await load(reset: true) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                        .vesperGlass(in: Circle(), interactive: true)
                }.buttonStyle(.plain).accessibilityLabel("刷新梦境")
            }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 18)
            if !status.isEmpty {
                HStack {
                    Text(status).font(.caption).textSelection(.enabled)
                    Button("重试") { Task { await load(reset: true) } }
                }.foregroundStyle(VesperTheme.muted).padding(20)
            }
            if rows.isEmpty {
                VStack(spacing: 14) {
                    if busy { ProgressView() }
                    else { Image(systemName: "moon").font(.largeTitle) }
                    Text("等下一场梦，慢慢落在这里。")
                        .font(.system(.title3, design: .serif))
                }.foregroundStyle(VesperTheme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $page) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        DreamJournalPage(row: row, open: { selected = row }).tag(index)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
                    .accessibilityIdentifier("dream-archive")
                HStack {
                    Text(String(format: "%02d / %02d", page + 1, rows.count))
                        .font(.system(.subheadline, design: .monospaced))
                    Spacer()
                    Button { withAnimation { page = max(0, page - 1) } } label: {
                        Image(systemName: "arrow.left").frame(width: 44, height: 44)
                    }.disabled(page == 0).accessibilityLabel("上一个梦")
                    Button { Task { await advance() } } label: {
                        Image(systemName: "arrow.right").frame(width: 44, height: 44)
                    }.disabled(busy || (page >= rows.count - 1 && offset >= total))
                        .accessibilityLabel("下一个梦")
                }.padding(.horizontal, 28).padding(.bottom, 10)
            }
        }.foregroundStyle(VesperTheme.ink)
            .accessibilityIdentifier("dream-archive")
            .task(id: store.baseURL + "\n" + store.token) {
                library.api = store.api; rows = []; offset = 0; total = 0
                await load(reset: true)
            }
            .sheet(item: $selected, onDismiss: { Task { await load(reset: true) } }) { row in
                NavigationStack {
                    LibraryRecordView(library: library, id: row.id, dream: true)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
                }.presentationDragIndicator(.visible)
            }
    }
    private func advance() async {
        if page + 1 < rows.count { withAnimation { page += 1 }; return }
        guard offset < total, !busy else { return }
        let previousCount = rows.count
        await load(reset: false)
        if rows.count > previousCount { withAnimation { page = previousCount } }
    }
    private func load(reset: Bool) async {
        if !reset && busy { return }
        generation += 1; let ticket = generation
        let start = reset ? 0 : offset
        busy = true; status = ""
        defer { if ticket == generation { busy = false } }
        do {
            var params = URLComponents()
            params.queryItems = [URLQueryItem(name: "kind", value: "dream"), URLQueryItem(name: "offset", value: String(start)),
                                 URLQueryItem(name: "limit", value: "40"), URLQueryItem(name: "include_superseded", value: "false")]
            let response = try await library.request("/api/memories?" + (params.percentEncodedQuery ?? ""))
            try Task.checkCancellation()
            guard ticket == generation else { return }
            let page = response["items"].array
            let dreams = page.filter { $0["kind"].string == "dream" }
            var seen = Set<String>()
            rows = ((reset ? [] : rows) + dreams).filter { seen.insert($0.id).inserted }
            offset = start + page.count
            total = Int(response["total"].number)
            self.page = min(self.page, max(0, rows.count - 1))
            status = response["warnings"].array.map(\.string).joined(separator: " · ")
        } catch {
            if ticket == generation && !Task.isCancelled {
                if reset { rows = []; offset = 0; total = 0 }
                status = error.localizedDescription
            }
        }
    }
}

private struct DreamJournalPage: View {
    let row: JSONValue
    let open: () -> Void
    var body: some View {
        let explicitTitle = row["details"]["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DreamDisplay.date(row).map { DreamDisplay.format($0, pattern: "dd") } ?? "—")
                        .font(.system(size: 46, weight: .ultraLight, design: .serif))
                    Text(DreamDisplay.date(row).map { DreamDisplay.format($0, pattern: "yyyy年M月") } ?? "日期未记录")
                        .font(.caption).foregroundStyle(VesperTheme.muted)
                }
                Spacer()
                Image(systemName: "moonphase.waning.gibbous")
                    .font(.system(size: 23, weight: .ultraLight)).foregroundStyle(VesperTheme.muted)
            }
            Rectangle().fill(VesperTheme.ink.opacity(0.2)).frame(height: 1)
            if !explicitTitle.isEmpty && !["梦", "梦与想象", "模拟梦境"].contains(explicitTitle) {
                Text(explicitTitle).font(.system(size: 21, weight: .regular, design: .serif))
            }
            ScrollView {
                Text(DreamDisplay.text(row)).font(.system(size: 17, weight: .regular, design: .serif))
                    .lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.scrollDismissesKeyboard(.interactively)
            HStack {
                Text("梦与想象 · 非真实经历")
                    .font(.caption2).foregroundStyle(VesperTheme.muted)
                Spacer()
                Button("来源与修订") { open() }.font(.caption.weight(.semibold))
            }
        }
        .padding(22)
        .frame(width: min(700, max(240, geometry.size.width - 36)),
               height: max(240, geometry.size.height - 30), alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(VesperTheme.palette == .black ? Color.black.opacity(0.72) : Color.white.opacity(0.82))
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityIdentifier("dream-" + row.id)
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
    @State private var showingIndex = false
    @State private var galaxyRevision = 0
    @State private var filtering = false
    @State private var selected: JSONValue?

    var body: some View {
        Group {
            if showingIndex { index }
            else { MemoryGalaxyView().id(galaxyRevision) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { modeBar }
        .foregroundStyle(VesperTheme.ink)
        .task { library.api = store.api; if showingIndex { await load() } }
        .onChange(of: showingIndex) { _, visible in if visible { refresh() } }
        .onChange(of: kind) { _, _ in refresh() }
        .sheet(isPresented: $adding) {
            LibraryEditor(library: library, record: nil) {
                if showingIndex { refresh() } else { galaxyRevision += 1 }
            }
        }
        .sheet(isPresented: $filtering) { filters }
        .sheet(item: $selected, onDismiss: { refresh() }) { row in
            NavigationStack { LibraryRecordView(library: library, id: row.id).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } } }
                .presentationDragIndicator(.visible)
        }
    }
    private var index: some View {
        VStack(spacing: 0) {
            Text("按时间翻看留下的片段。")
                .font(.system(.subheadline, design: .serif)).foregroundStyle(VesperTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
            search
            categories
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(VesperTheme.muted).padding(.vertical, 6) }
                    if busy { ProgressView().frame(maxWidth: .infinity).padding() }
                    if rows.isEmpty && !busy && status.isEmpty {
                        Text(query.isEmpty ? "这里还没有记忆，等值得留下的内容。" : "没有找到相关记忆，换几个关键词试试。")
                            .font(.subheadline).foregroundStyle(VesperTheme.muted).padding(.vertical, 30)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { selected = row } label: { LibraryPreviewCard(row: row, featured: index == 0) }.buttonStyle(.plain)
                    }
                    pagination
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 90)
            }.scrollDismissesKeyboard(.interactively)
                .background(VesperTheme.surface.opacity(0.66))
                .refreshable { await load() }
        }.frame(maxWidth: 780).frame(maxWidth: .infinity)
    }
    private var modeBar: some View {
        HStack(spacing: 10) {
            Button { showingIndex = false } label: {
                Label("星图", systemImage: "sparkles")
                    .font(.subheadline.weight(showingIndex ? .regular : .semibold))
                    .padding(.horizontal, 15).frame(height: 42)
                    .vesperGlass(in: Capsule(), interactive: true)
            }.accessibilityAddTraits(showingIndex ? [] : .isSelected)
            Button { showingIndex = true } label: {
                Label("索引", systemImage: "text.alignleft")
                    .font(.subheadline.weight(showingIndex ? .semibold : .regular))
                    .padding(.horizontal, 15).frame(height: 42)
                    .vesperGlass(in: Capsule(), interactive: true)
            }.accessibilityAddTraits(showingIndex ? .isSelected : [])
            Spacer()
            Button { adding = true } label: { Image(systemName: "plus").frame(width: 44, height: 44).vesperGlass(in: Circle(), interactive: true) }.accessibilityLabel("新增记忆")
        }.buttonStyle(.plain)
            .foregroundStyle(showingIndex ? VesperTheme.ink : .white)
            .padding(.horizontal, 20).padding(.vertical, 10)
    }
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(VesperTheme.muted)
            TextField("找一句话，一件旧事…", text: $query).font(.subheadline).submitLabel(.search).onSubmit { refresh() }
            if !query.isEmpty {
                Button { query = ""; refresh() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索")
            }
            Button { filtering = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 32) }.accessibilityLabel("筛选记忆")
            }.padding(.horizontal, 12).padding(.vertical, 5).vesperGlass(in: RoundedRectangle(cornerRadius: 15))
            .padding(.horizontal, 20).padding(.bottom, 12)
    }
    private var categories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 26) {
                ForEach(memoryCategories, id: \.self) { value in
                    Button { kind = value } label: {
                        VStack(spacing: 8) {
                            Text(libraryKind(value)).font(.subheadline.weight(kind == value ? .semibold : .regular))
                                .foregroundStyle(kind == value ? VesperTheme.ink : VesperTheme.muted)
                            Rectangle().fill(kind == value ? VesperTheme.ink : .clear).frame(height: 1)
                        }.fixedSize(horizontal: true, vertical: false)
                    }.buttonStyle(.plain).accessibilityAddTraits(kind == value ? .isSelected : [])
                }
            }.padding(.horizontal, 22)
        }.padding(.bottom, 10)
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

struct LibraryPreviewCard: View {
    let row: JSONValue
    var featured = false
    var body: some View {
        let explicitTitle = row["details"]["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(VesperTheme.ink.opacity(featured ? 0.8 : 0.35))
                .frame(width: featured ? 8 : 6, height: featured ? 8 : 6)
                .frame(width: 12, height: 12).padding(.top, 4)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(memoryDate(row["occurred_at"].string))
                    if row["kind"].string == "reflection" { Text("·  感受") }
                    if row["active"].number == 0 { Text("·  历史记录") }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption2)
                }.font(.caption2).foregroundStyle(VesperTheme.muted)
                if !explicitTitle.isEmpty {
                    Text(explicitTitle)
                        .font(.system(size: featured ? 18 : 16, weight: .medium, design: .serif))
                        .lineLimit(2).foregroundStyle(VesperTheme.ink)
                    Text(memorySummary(row)).font(.system(size: 13)).lineSpacing(2)
                        .lineLimit(featured ? 3 : 2).foregroundStyle(VesperTheme.muted)
                } else {
                    Text(memorySummary(row))
                        .font(.system(size: featured ? 17 : 16, weight: .regular, design: .serif))
                        .lineSpacing(3).lineLimit(3).foregroundStyle(VesperTheme.ink)
                }
                Rectangle().fill(VesperTheme.ink.opacity(0.12)).frame(height: 1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(alignment: .topLeading) {
            Rectangle().fill(VesperTheme.ink.opacity(0.16)).frame(width: 1)
                .padding(.leading, 5.5).padding(.top, 20)
        }
        .padding(.top, 12).padding(.bottom, 6)
        .accessibilityIdentifier("memory-" + row.id)
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
                VStack(alignment: .leading, spacing: 22) {
                    if record != .null {
                        HStack {
                            Text(dream ? "DREAM  /  梦与想象" : libraryKind(record["kind"].string))
                                .font(.caption2.weight(.semibold)).tracking(2)
                            Spacer()
                            Image(systemName: dream ? "moon.stars" : "circle.dotted")
                        }.foregroundStyle(VesperTheme.muted)
                        Text(dream ? DreamDisplay.title(record) : memoryTitle(record))
                            .font(.system(size: 31, weight: .regular, design: .serif))
                        Text(dream ? (DreamDisplay.date(record).map { DreamDisplay.format($0, pattern: "yyyy年M月d日") } ?? "日期未记录") : memoryDate(record["occurred_at"].string))
                            .font(.caption).foregroundStyle(VesperTheme.muted)
                        if ["dream", "reflection"].contains(record["kind"].string) {
                            Text(record["kind"].string == "dream" ? "虚构，非真实经历" : "主观感受，不等同于事实")
                                .font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        Rectangle().fill(VesperTheme.ink.opacity(0.18)).frame(height: 1)
                        Text(dream ? DreamDisplay.text(record) : record["body"].string)
                            .font(.system(size: dream ? 21 : 19, weight: .regular, design: .serif))
                            .lineSpacing(dream ? 10 : 8).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                        if record["withdrawal"] != .null { Text("已撤回：" + record["withdrawal"]["reason"].string).font(.caption) }
                        if record["review"] != .null { Text("待核对：" + record["review"]["reason"].string).font(.caption) }
                        Rectangle().fill(VesperTheme.ink.opacity(0.18)).frame(height: 1)
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
                }.padding(25).padding(.top, 16).padding(.bottom, 80)
                    .frame(maxWidth: 740).frame(maxWidth: .infinity)
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

struct LibraryEditor: View {
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




/// A candidate stays out of memory until the user explicitly saves it.
struct MemoryCandidateReviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = SharedMemoryLibrary()
    @State private var candidate: JSONValue
    @State private var editing = false
    @State private var busy = false
    @State private var error = ""
    let onReviewed: () -> Void
    let onLater: (String) -> Void

    init(candidate: JSONValue, onReviewed: @escaping () -> Void, onLater: @escaping (String) -> Void) {
        _candidate = State(initialValue: candidate)
        self.onReviewed = onReviewed
        self.onLater = onLater
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Ash 想记住这件事。请核对内容，确认前不会写入记忆。")
                        .font(.subheadline).foregroundStyle(VesperTheme.muted)
                    VStack(alignment: .leading, spacing: 12) {
                        if !candidate["details"]["title"].string.isEmpty {
                            Text(candidate["details"]["title"].string).font(.headline)
                        }
                        Text(candidate["body"].string).textSelection(.enabled)
                        if !candidate["source"].string.isEmpty {
                            Text("来源：" + candidate["source"].string)
                                .font(.caption).foregroundStyle(VesperTheme.muted)
                        }
                        ForEach(Array(candidate["details"]["evidence"].array.enumerated()), id: \.offset) { _, evidence in
                            if !evidence["quote"].string.isEmpty {
                                Text("原话：" + evidence["quote"].string)
                                    .font(.caption).foregroundStyle(VesperTheme.muted)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .vesperMaterial(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                    Button { Task { await review("accept") } } label: {
                        Text("正确，保存记忆").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                    HStack {
                        Button("修改内容") { editing = true }.disabled(busy)
                        Spacer()
                        Button("不保存", role: .destructive) { Task { await review("reject") } }.disabled(busy)
                    }.buttonStyle(.bordered)
                }.padding(20)
            }
            .background { Background() }
            .navigationTitle("核对记忆")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("稍后") { onLater(candidate.id); dismiss() }.disabled(busy)
            } }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)
        .sheet(isPresented: $editing) {
            LibraryEditor(library: library, record: candidate, saved: { Task { await reload() } }, candidateID: candidate.id)
        }
        .task { library.api = store.api }
    }

    private func reload() async {
        do {
            let result = try await store.api.request("/api/memory/candidates")
            if let updated = result["items"].array.first(where: { $0.id == candidate.id }) { candidate = updated }
        } catch { self.error = error.localizedDescription }
    }

    private func review(_ action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await store.api.request("/api/memory/candidates", method: "POST", body: .object([
                "id": .string(candidate.id), "action": .string(action)
            ]))
            onReviewed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// The galaxy reads the same active Shared Memory records as the list above.
// Its positions are derived locally; no memory text is published as a web page.
private struct GalaxyMemory: Identifiable {
    let id: String
    let row: JSONValue
    let title: String
    let date: Date?
    let category: String
    let importance: Int
    let pinned: Bool
    var radius: Double = 0

    init(_ row: JSONValue) {
        self.id = row.id
        self.row = row
        self.title = row["kind"].string == "dream" ? DreamDisplay.title(row) : memoryTitle(row)
        if let parsed = DreamDisplay.date(row) {
            self.date = parsed
        } else {
            let raw = row["occurred_at"].string
            let day = String(raw.prefix(10))
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            self.date = formatter.date(from: day)
        }
        let domain = row["details"]["domain"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = domain.isEmpty ? row["kind"].string : domain
        let score = Int(row["details"]["importance"].number > 0
                        ? row["details"]["importance"].number : row["importance"].number)
        self.importance = score > 0 ? min(10, score) : 4
        self.pinned = row["pinned"].bool || row["details"]["pinned"].bool
    }

    var body: String { row["body"].string }
    var categoryName: String { libraryKind(category) }
}

struct MemoryGalaxyView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var library = SharedMemoryLibrary()
    @State private var stars: [GalaxyMemory] = []
    @State private var selectedID: String?
    @State private var detail: GalaxyMemory?
    @State private var loading = false
    @State private var error = ""
    @State private var rotation = 0.0
    @State private var dragStart = 0.0
    @State private var tilt = 0.32
    @State private var tiltStart = 0.32
    @State private var zoom = 1.0
    @State private var zoomStart = 1.0

    private let night = Color(red: 0.018, green: 0.012, blue: 0.038)
    private var selected: GalaxyMemory? { stars.first { $0.id == selectedID } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Background().ignoresSafeArea()
                LinearGradient(stops: [
                    .init(color: night.opacity(0.87), location: 0),
                    .init(color: night.opacity(0.96), location: 0.42),
                    .init(color: night.opacity(0.98), location: 1)
                ], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                        paused: reduceMotion || selectedID != nil)) { timeline in
                    Canvas(opaque: false) { context, size in
                        draw(in: context, size: size, date: timeline.date)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            // Moving a finger to the right turns the near side of the galaxy right.
                            rotation = dragStart - Double(value.translation.width) / 210
                            tilt = min(0.78, max(-0.78, tiltStart + Double(value.translation.height) / 450))
                        }
                        .onEnded { _ in dragStart = rotation; tiltStart = tilt })
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { value in zoom = min(2.8, max(0.65, zoomStart * Double(value))) }
                        .onEnded { _ in zoomStart = zoom })
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        select(at: value.location, size: geometry.size, date: timeline.date)
                    })
                }
                VStack(spacing: 0) {
                    Text("Memory Galaxy")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                        .foregroundStyle(.white.opacity(0.93))
                    Text("把一起走过的，留在星光里。")
                        .font(.caption).foregroundStyle(.white.opacity(0.52))
                    Spacer()
                    if loading {
                        ProgressView("正在寻找记忆…").tint(.white)
                            .foregroundStyle(.white.opacity(0.75)).padding(.bottom, 38)
                    } else if !error.isEmpty {
                        VStack(spacing: 12) {
                            Text(error).font(.subheadline).multilineTextAlignment(.center)
                            Button("重新加载") { Task { await load() } }.font(.subheadline.weight(.semibold))
                        }.foregroundStyle(.white.opacity(0.78)).padding(.horizontal, 30).padding(.bottom, 38)
                    } else if stars.isEmpty {
                        Text("这里还没有可以点亮的记忆。")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.6)).padding(.bottom, 38)
                    } else if let selected {
                        memoryText(selected, availableWidth: geometry.size.width)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        HStack(spacing: 7) {
                            Image(systemName: "hand.draw")
                            Text("拖动旋转 · 双指缩放 · 点一颗星")
                        }.font(.caption).foregroundStyle(.white.opacity(0.46)).padding(.bottom, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 16)
                .allowsHitTesting(selected != nil || !error.isEmpty)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .foregroundStyle(.white)
                    .accessibilityLabel("刷新记忆银河")
            }
        }
        .task(id: store.baseURL + "\n" + store.token) {
            library.api = store.api
            await load()
        }
        .sheet(item: $detail) { star in
            NavigationStack {
                LibraryRecordView(library: library, id: star.id, dream: star.row["kind"].string == "dream")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detail = nil } } }
            }.presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("memory-galaxy")
    }

    private func memoryText(_ star: GalaxyMemory, availableWidth: CGFloat) -> some View {
        let charactersPerLine = max(16, Int((availableWidth - 80) / 16))
        let lineCount = star.body.components(separatedBy: .newlines).reduce(0) { count, paragraph in
            count + max(1, (paragraph.count + charactersPerLine - 1) / charactersPerLine)
        }
        let textHeight = min(CGFloat(210), max(CGFloat(32), CGFloat(lineCount) * 25))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle")
                    .foregroundStyle(color(for: star.category)).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(star.title).font(.system(.title3, design: .serif)).fontWeight(.medium)
                    Text((star.date.map { DreamDisplay.format($0, pattern: "yyyy年M月d日") } ?? "日期未记录") + " · " + star.categoryName)
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
                Button { withAnimation(.easeOut(duration: 0.3)) { selectedID = nil } } label: {
                    Image(systemName: "xmark").font(.subheadline).padding(8)
                }.accessibilityLabel("关闭记忆")
            }
            ScrollView {
                Text(star.body).font(.system(.subheadline, design: .serif))
                    .lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: textHeight)
            Button("查看来源与详情") { detail = star }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white.opacity(0.93))
        .padding(.horizontal, 25).padding(.top, 45).padding(.bottom, 25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, night.opacity(0.72), night.opacity(0.97)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true; error = ""
        defer { loading = false }
        do {
            var fetched: [JSONValue] = []
            var fetchedIDs = Set<String>()
            var offset = 0
            repeat {
                var params = URLComponents()
                params.queryItems = [URLQueryItem(name: "offset", value: String(offset)),
                                     URLQueryItem(name: "limit", value: "80"),
                                     URLQueryItem(name: "include_superseded", value: "false")]
                let response = try await library.request("/api/memories?" + (params.percentEncodedQuery ?? ""))
                let page = response["items"].array
                let new = page.filter { fetchedIDs.insert($0.id).inserted }
                fetched += new
                offset += page.count
                if new.isEmpty || offset >= Int(response["total"].number) { break }
            } while true
            try Task.checkCancellation()
            var seen = Set<String>()
            var mapped = fetched.filter { seen.insert($0.id).inserted }.map(GalaxyMemory.init)
            mapped.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            let dated = mapped.compactMap(\.date)
            let earliest = dated.first ?? .now
            let span = max(1, (dated.last ?? earliest).timeIntervalSince(earliest))
            for index in mapped.indices {
                let progress = mapped[index].date.map { max(0, min(1, $0.timeIntervalSince(earliest) / span)) }
                    ?? Double(index) / Double(max(1, mapped.count - 1))
                mapped[index].radius = index == 0 ? 0 : 0.12 + pow(progress, 0.82) * 0.88
            }
            stars = mapped
            if !stars.contains(where: { $0.id == selectedID }) { selectedID = nil }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func color(for category: String) -> Color {
        switch category {
        case "episode", "恋爱", "我们的故事": Color(red: 1, green: 0.59, blue: 0.78)
        case "agreement", "家庭", "珍贵": Color(red: 1, green: 0.81, blue: 0.57)
        case "preference", "编程", "AI": Color(red: 0.62, green: 0.7, blue: 1)
        case "reflection", "情绪", "自省": Color(red: 0.78, green: 0.63, blue: 1)
        case "dream": Color(red: 0.59, green: 0.83, blue: 0.95)
        default: Color(red: 0.73, green: 0.8, blue: 0.92)
        }
    }

    private func point(_ index: Int, count: Int, radius: Double, size: CGSize, date: Date) -> CGPoint {
        let center = galaxyCenter(in: size)
        let spread = galaxySpread(in: size)
        let angle = Double(index) * 2.399963229728653 + rotation + phase(at: date)
        let thickness = (Self.noise(index * 19 + 7) - 0.5) * (10 + 20 * (1 - radius)) * zoom
        return CGPoint(x: center.x + cos(angle) * radius * spread,
                       y: center.y + sin(angle) * radius * spread * tilt + thickness)
    }

    private func galaxyCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * 0.52)
    }

    private func galaxySpread(in size: CGSize) -> Double {
        min(size.width * 0.64, size.height * 0.42) * zoom
    }

    private func phase(at date: Date) -> Double {
        reduceMotion ? 0 : date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600) * 0.008
    }

    private func select(at location: CGPoint, size: CGSize, date: Date) {
        var nearest: (id: String, distance: CGFloat)?
        for (index, star) in stars.enumerated() {
            let center = point(index, count: stars.count, radius: star.radius, size: size, date: date)
            let distance = hypot(center.x - location.x, center.y - location.y)
            if distance < 28 && (nearest == nil || distance < nearest!.distance) {
                nearest = (star.id, distance)
            }
        }
        withAnimation(.easeOut(duration: 0.35)) { selectedID = nearest?.id }
    }

    private static func noise(_ seed: Int) -> Double {
        var value = UInt64(truncatingIfNeeded: seed) &* 0x9E3779B97F4A7C15
        value ^= value >> 30; value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27; value &*= 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value & 0xFFFFFF) / Double(0xFFFFFF)
    }

    private func draw(in context: GraphicsContext, size: CGSize, date: Date) {
        let center = galaxyCenter(in: size)
        let spread = galaxySpread(in: size)
        for index in 0..<190 {
            let x = Self.noise(index * 41 + 2) * size.width
            let y = Self.noise(index * 37 + 4) * size.height
            let d = CGFloat(0.5 + Self.noise(index * 29 + 6) * 1.2)
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)),
                         with: .color(.white.opacity(0.08 + Self.noise(index * 23 + 5) * 0.18)))
        }
        for radius in [0.44, 0.72, 1.03, 1.34] {
            let horizontal = spread * radius
            let vertical = horizontal * abs(tilt)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - horizontal, y: center.y - vertical,
                                                   width: horizontal * 2, height: vertical * 2)),
                           with: .color(Color(red: 0.83, green: 0.69, blue: 0.91).opacity(0.10)),
                           lineWidth: 0.7)
        }
        let haze = Color(red: 0.56, green: 0.40, blue: 0.68)
        let disk = CGRect(x: center.x - spread * 1.16, y: center.y - spread * 0.39,
                          width: spread * 2.32, height: spread * 0.78)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: CGFloat(spread * 0.12)))
            layer.fill(Path(ellipseIn: disk), with: .radialGradient(
                Gradient(colors: [haze.opacity(0.33), haze.opacity(0.12), .clear]),
                center: center, startRadius: 0, endRadius: spread * 1.14))
        }
        let core = CGRect(x: center.x - spread * 0.52, y: center.y - spread * 0.19,
                          width: spread * 1.04, height: spread * 0.38)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: CGFloat(spread * 0.055)))
            layer.fill(Path(ellipseIn: core), with: .radialGradient(
                Gradient(colors: [Color(red: 1, green: 0.93, blue: 0.99).opacity(0.68),
                                  Color(red: 0.79, green: 0.65, blue: 0.85).opacity(0.24), .clear]),
                center: center, startRadius: 0, endRadius: spread * 0.53))
        }
        for index in 0..<2800 {
            let outer = pow(Self.noise(index * 5 + 1), index.isMultiple(of: 4) ? 0.75 : 1.6)
            let angle = Self.noise(index * 13 + 3) * (.pi * 2) + rotation + phase(at: date)
            let radial = outer * spread * 1.12
            let thickness = (Self.noise(index * 11 + 9) - 0.5) * (12 + (1 - outer) * 38) * zoom
            let x = center.x + cos(angle) * radial
            let y = center.y + sin(angle) * radial * tilt + thickness
            let diameter = CGFloat(0.45 + Self.noise(index * 17 + 5) * 1.45)
            let tint = index % 13 == 0 ? Color(red: 1, green: 0.75, blue: 0.83)
                : index % 9 == 0 ? Color(red: 0.74, green: 0.78, blue: 1) : .white
            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: diameter, height: diameter)),
                         with: .color(tint.opacity(0.18 + (1 - outer) * 0.38)))
        }
        if let selected, let selectedIndex = stars.firstIndex(where: { $0.id == selected.id }) {
            let origin = point(selectedIndex, count: stars.count, radius: selected.radius, size: size, date: date)
            for (index, star) in stars.enumerated() where star.id != selected.id && star.category == selected.category {
                let end = point(index, count: stars.count, radius: star.radius, size: size, date: date)
                var line = Path(); line.move(to: origin); line.addLine(to: end)
                context.stroke(line, with: .color(color(for: selected.category).opacity(0.25)), lineWidth: 0.7)
            }
        }
        for (index, star) in stars.enumerated() {
            let point = point(index, count: stars.count, radius: star.radius, size: size, date: date)
            let important = star.pinned || star.importance >= 9 || index == 0
            let related = selectedID == nil || selectedID == star.id || selected?.category == star.category
            let diameter: CGFloat = index == 0 ? 9 : important ? 7 : star.importance >= 7 ? 5 : 3.5
            let color = color(for: star.category)
            context.fill(Path(ellipseIn: CGRect(x: point.x - diameter * 2, y: point.y - diameter * 2,
                                                width: diameter * 4, height: diameter * 4)),
                         with: .radialGradient(Gradient(colors: [color.opacity(related ? 0.42 : 0.07), .clear]),
                                               center: point, startRadius: 0, endRadius: diameter * 2))
            context.fill(Path(ellipseIn: CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                                width: diameter, height: diameter)),
                         with: .color(color.opacity(related ? 0.95 : 0.23)))
        }
    }
}
